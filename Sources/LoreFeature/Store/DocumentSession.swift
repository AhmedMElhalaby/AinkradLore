import Foundation
import Observation

/// One open document: its engine, its dirty state, its autosave, and its
/// conflict resolution.
///
/// The external-change guard used to live in `LoreStore.save` and applied only
/// to notes. It lives here now and applies to every document type, and the
/// three resolutions (reload / overwrite / save a copy) are real operations
/// rather than an error the UI had no affordance for.
@MainActor
@Observable
public final class DocumentSession: Identifiable {
    /// Stable identity, minted once at init. `url` is mutable (see below), so
    /// tab identity (SwiftUI `ForEach`, dictionary keys, etc.) must key off
    /// `id`, never off `url`.
    public let id = UUID()

    /// The file this session writes to. MUTABLE: `resolveBySavingCopy()`
    /// repoints it at the copy (see there). Callers that key tab identity off a
    /// session must follow this value rather than caching it.
    public private(set) var url: URL
    public let engine: any DocumentEngine

    public private(set) var isDirty = false
    public private(set) var conflict = false

    /// The last save failure that was NOT a conflict — disk full, permissions,
    /// a read-only volume, an engine refusing to round-trip. Conflicts have
    /// their own flag and their own three resolutions; everything else used to
    /// vanish into the autosave's `try?` with `isDirty` as the only hint.
    /// Cleared by every successful write and every successful resolution.
    public private(set) var lastSaveError: Error?

    /// True when the engine cannot write this document back faithfully — today
    /// only a `PlainTextEngine` whose bytes failed a strict UTF-8 decode. Such
    /// a session never autosaves and `saveNow()` refuses up front, so a single
    /// keystroke does not turn into one failed write per keystroke.
    public private(set) var isReadOnly: Bool

    /// Bumped on every successful `resolveByReloading()`. The engines' editor
    /// views seed their SwiftUI `@State` from the engine in `.onAppear`, so an
    /// in-place reload would otherwise leave the OLD text on screen — the user
    /// clicks "Reload" and sees nothing change. Views use this as part of their
    /// `.id()` so a reload forces a fresh view.
    public private(set) var reloadGeneration = 0

    private let coordinator: VaultIndexCoordinator
    /// mtime as of the last successful load or save. Detection is mtime-based
    /// and therefore best-effort: a write inside the filesystem's timestamp
    /// granularity can still slip through. A much smaller hole than not
    /// checking at all.
    private var baseline: Date
    private var saveTask: Task<Void, Never>?

    /// Cached `engine.indexPayload.title`. `indexPayload` is computed, and for
    /// markdown it scans the whole body to build an outline, so reading it from
    /// a SwiftUI `body` (a tab label redraws constantly) or per keystroke is a
    /// real cost. Refreshed only where the title can have changed AND the cost
    /// is already amortised: load, save, reload.
    private var cachedTitle: String

    private static let autosaveDelay: Duration = .milliseconds(500)
    /// One policy, one owner: the coordinator decides how long its own watcher
    /// ignores the echo of our writes.
    private static var selfWriteSuppressionWindow: TimeInterval {
        VaultIndexCoordinator.selfWriteSuppressionWindow
    }

    public init(url: URL, engine: any DocumentEngine, coordinator: VaultIndexCoordinator) {
        self.url = url
        self.engine = engine
        self.coordinator = coordinator
        self.baseline = Self.mtime(of: url) ?? .distantPast
        self.cachedTitle = engine.indexPayload.title
        // Same honest-but-temporary type switch as `copyState(from:)`; M3/M4
        // replace both with protocol requirements.
        self.isReadOnly = (engine as? PlainTextEngine)?.isLossilyDecoded == true
    }

    public static func open(url: URL, coordinator: VaultIndexCoordinator) throws -> DocumentSession {
        let engine = try EngineRegistry.load(url)
        return DocumentSession(url: url, engine: engine, coordinator: coordinator)
    }

    /// The title as of the last load or save — see `cachedTitle`.
    public var title: String { cachedTitle }

    /// Called by the engine's editor after every user mutation. Debounced, so
    /// typing produces one write per pause rather than one per keystroke.
    public func markChanged() {
        // A read-only document can never be written, so it is never marked
        // dirty either: scheduling an autosave would produce a failed write per
        // typing pause, and a dirty flag nothing can ever clear would make the
        // tab's close-confirmation nag forever on a file that cannot be saved.
        guard !isReadOnly else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            // A conflict is surfaced, never swallowed: the editor's text stays
            // intact until the user chooses a resolution.
            try? self.saveNow()
        }
    }

    /// Disarms a debounced autosave that has not fired yet.
    ///
    /// MUST be called by anything that stops owning this session — closing its
    /// tab, tearing the store down, switching vaults — and BEFORE deleting the
    /// file it points at. Without it the task armed by `markChanged` outlives
    /// the tab: the SwiftUI view, a captured `selectedTab` or a frame still in
    /// flight keeps the session alive for the remaining 500ms, and the save
    /// lands afterwards. On the delete path that RECREATES the file the user
    /// just deleted, containing the content they chose to discard; on the
    /// "Close anyway → those edits are lost" path it silently persists them
    /// anyway, making the dialog a lie.
    ///
    /// Deliberately does NOT clear `isDirty`: the in-memory document really is
    /// unsaved, and callers that want it on disk call `saveNow()` first.
    public func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    public func saveNow() throws {
        try guardWritable()
        if let disk = Self.mtime(of: url), disk > baseline {
            // A conflict is not a `lastSaveError`: it has its own flag and its
            // own three resolutions. Conflating them would make the UI show
            // both a banner and an error for one situation.
            conflict = true
            throw LoreError.externalChange(url)
        }
        try write()
    }

    public func resolveByOverwriting() throws {
        try guardWritable()
        try write()
    }

    /// Session-level write policy, enforced before any engine call. Today only
    /// `PlainTextEngine` self-guards; an engine that did not would otherwise
    /// bypass this entirely.
    private func guardWritable() throws {
        guard isReadOnly else { return }
        let error = EngineError.notRoundTrippable(url)
        lastSaveError = error
        throw error
    }

    public func resolveByReloading() throws {
        let fresh = try EngineRegistry.load(url)
        // The engine is `let`, so reloading copies the fresh contents into the
        // engine this session already owns rather than swapping the object.
        try copyState(from: fresh)
        baseline = Self.mtime(of: url) ?? .distantPast
        cachedTitle = engine.indexPayload.title
        conflict = false
        isDirty = false
        lastSaveError = nil
        reloadGeneration += 1
    }

    /// Writes our version beside the original as `name (Lore copy).ext`,
    /// leaving the on-disk file untouched, and ADOPTS the copy: from here on
    /// this session edits and saves the copy.
    ///
    /// "My version lives here now, and the file I was fighting over is left
    /// alone" is the only reading under which continuing to type is safe. The
    /// alternative — keep pointing at the original — leaves the session
    /// permanently in conflict with a file it will never win against, so every
    /// subsequent autosave fails silently through its `try?` and the user's
    /// ongoing work is persisted nowhere while the tab looks clean.
    @discardableResult
    public func resolveBySavingCopy() throws -> URL {
        try guardWritable()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(base) (Lore copy).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base) (Lore copy \(n)).\(ext)")
            n += 1
        }
        coordinator.suppressWatcher(for: Self.selfWriteSuppressionWindow)
        try engine.save(to: candidate)
        url = candidate
        baseline = Self.mtime(of: candidate) ?? .distantPast
        cachedTitle = engine.indexPayload.title
        conflict = false
        isDirty = false
        lastSaveError = nil
        try? coordinator.indexDocument(engine, at: candidate)
        return candidate
    }

    /// The document this session edits was renamed or moved on disk. Follow it.
    ///
    /// `url` is already mutable (`resolveBySavingCopy` adoption); this is the
    /// same move for a different reason. The baseline MUST be refreshed too:
    /// it describes the old file, and left stale the session's next save either
    /// sees a "newer" file and raises a phantom conflict, or — worse — sees an
    /// older one and writes over the move. `conflict` is cleared for the same
    /// reason: a banner about a file that no longer exists is not actionable.
    ///
    /// `isDirty` is deliberately NOT cleared: unsaved edits are still unsaved,
    /// they just belong to a file with a new name now.
    public func adoptRenamed(_ newURL: URL) {
        url = newURL
        baseline = Self.mtime(of: newURL) ?? .distantPast
        conflict = false
        lastSaveError = nil
    }

    private func write() throws {
        coordinator.suppressWatcher(for: Self.selfWriteSuppressionWindow)
        do {
            try engine.save(to: url)
        } catch {
            // Disk full, permissions, a read-only volume: not a conflict, and
            // previously invisible because the autosave discards this throw.
            lastSaveError = error
            throw error
        }
        baseline = Self.mtime(of: url) ?? .distantPast
        cachedTitle = engine.indexPayload.title
        isDirty = false
        conflict = false
        lastSaveError = nil
        // The file is truth; the index is derived. A failed index write must
        // never make a successful save look like a failure.
        try? coordinator.indexDocument(engine, at: url)
    }

    /// Replaces this session's engine contents with `fresh`'s. Implemented per
    /// engine because only the engine knows its own document model.
    ///
    /// This switch is the one place M0 leaks engine knowledge into the shell.
    /// M3/M4 must replace it with a `replaceContents(with:)` requirement on
    /// `DocumentEngine`; with two engines that requirement is still
    /// speculative, and the switch is honest about being temporary.
    private func copyState(from fresh: any DocumentEngine) throws {
        switch (engine, fresh) {
        case let (mine as MarkdownEngine, theirs as MarkdownEngine):
            mine.note = theirs.note
        case let (mine as PlainTextEngine, theirs as PlainTextEngine):
            mine.text = theirs.text
        default:
            throw EngineError.unsupported(url)
        }
    }

    private static func mtime(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
