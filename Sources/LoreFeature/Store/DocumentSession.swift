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
public final class DocumentSession {
    public let url: URL
    public let engine: any DocumentEngine

    public private(set) var isDirty = false
    public private(set) var conflict = false

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
    private static let selfWriteSuppressionWindow: TimeInterval = 1.0

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
        isDirty = true
        // A read-only document can never be written; scheduling an autosave
        // would only produce a failed write per pause, forever.
        guard !isReadOnly else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            // A conflict is surfaced, never swallowed: the editor's text stays
            // intact until the user chooses a resolution.
            try? self.saveNow()
        }
    }

    public func saveNow() throws {
        guard !isReadOnly else { throw EngineError.notRoundTrippable(url) }
        if let disk = Self.mtime(of: url), disk > baseline {
            conflict = true
            throw LoreError.externalChange(url)
        }
        try write()
    }

    public func resolveByOverwriting() throws {
        try write()
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
        reloadGeneration += 1
    }

    /// Writes our version beside the original as `name (Lore copy).ext`,
    /// leaving the on-disk file untouched. The escape hatch that makes the
    /// other two resolutions safe to offer.
    @discardableResult
    public func resolveBySavingCopy() throws -> URL {
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
        try engine.save(to: candidate)
        conflict = false
        isDirty = false
        return candidate
    }

    private func write() throws {
        coordinator.suppressWatcher(for: Self.selfWriteSuppressionWindow)
        try engine.save(to: url)
        baseline = Self.mtime(of: url) ?? .distantPast
        cachedTitle = engine.indexPayload.title
        isDirty = false
        conflict = false
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
