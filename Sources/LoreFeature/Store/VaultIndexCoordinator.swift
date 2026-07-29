import Foundation
import Observation

/// Owns the vault's derived state: the SQLite index, the folder watcher, and
/// the rescan lifecycle. Extracted from `LoreStore` unchanged — every comment
/// below records a real bug the code around it fixes.
@MainActor
@Observable
public final class VaultIndexCoordinator {
    public private(set) var rows: [IndexRow] = []
    public private(set) var vaultRoot: URL?

    private let indexPath: URL
    private var index: LoreIndex?
    private var watcher: FolderWatcher?
    /// While `Date() < suppressWatcherUntil`, `FolderWatcher` callbacks are
    /// ignored — see `save(_:overwritingExternalChanges:)`.
    private var suppressWatcherUntil: Date = .distantPast
    /// A background rescan is in flight.
    private var isRebuilding = false
    /// A vault change arrived while a rescan was running — run once more after.
    private var rebuildRequestedAgain = false

    /// How long after our own write a watcher event is treated as the echo of
    /// that write. Generous enough to cover FSEvents' coalescing latency,
    /// short enough that a genuine external edit arriving right after a save
    /// is still picked up on the next event.
    static let selfWriteSuppressionWindow: TimeInterval = 1.0

    public init(indexPath: URL) {
        self.indexPath = indexPath
    }

    public func activate(root: URL) throws {
        vaultRoot = root
        index = try LoreIndex(path: indexPath)
        // Paint immediately from whatever the index already holds — a reopen
        // then shows the vault instantly — and refresh from disk in the
        // background. Crucially NOT a synchronous `rebuild()`: `activate` runs
        // from `LoreStore.init`, which the host calls from `LoreApp.store(for:)`
        // inside `makeRootView` — i.e. inside a SwiftUI `body` evaluation. A
        // whole-vault scan there froze the UI on first open, for as long as the
        // user's vault was large.
        rows = (try? index?.all()) ?? []
        startBackgroundRebuild()
        watcher = FolderWatcher(url: root) { [weak self] in self?.handleVaultChange() }
    }

    /// Releases everything this store owns: the vault watcher, any in-flight
    /// rescan, and the SQLite index (and with it its file descriptor).
    ///
    /// Called from `LoreApp.teardown` when the host closes this instance. Until
    /// generation 8 there was no way for the host to say that, so all of this
    /// leaked for the lifetime of the process every time Lore was removed.
    public func shutdown() {
        watcher = nil
        rebuildRequestedAgain = false
        index = nil
        rows = []
        vaultRoot = nil
    }

    /// Watcher entry point. Drops the echo of our own writes so a save doesn't
    /// trigger a full-vault rescan of a vault we just updated in place.
    func handleVaultChange() {
        guard Date() >= suppressWatcherUntil else { return }
        startBackgroundRebuild()
    }

    /// Ignore watcher callbacks for `interval` — used across our own writes so
    /// a save does not trigger a full-vault rescan of a vault we just updated
    /// in place. See the original rationale on `save`.
    func suppressWatcher(for interval: TimeInterval) {
        suppressWatcherUntil = Date().addingTimeInterval(interval)
    }

    /// Test seam: wait until no background rescan is in flight.
    ///
    /// `activate` kicks one off, and `async` tests suspend often enough for its
    /// `replaceAll` to land in the middle of one — wiping notes the test had
    /// already created. Synchronous `XCTest` cases never yielded, so this only
    /// became necessary with the `async` swift-testing suites.
    func settleForTesting() async {
        while isRebuilding { await Task.yield() }
    }

    /// Kicks off an off-actor rescan, coalescing with one already in flight.
    ///
    /// FSEvents delivers bursts (a `git checkout` in the vault is hundreds of
    /// events), and each used to start its own full synchronous rescan on the
    /// main actor. Now at most one runs at a time, off the main actor, and a
    /// burst arriving during one schedules exactly one follow-up.
    func startBackgroundRebuild() {
        guard !isRebuilding else { rebuildRequestedAgain = true; return }
        isRebuilding = true
        Task { [weak self] in
            await self?.performBackgroundRebuild()
        }
    }

    private func performBackgroundRebuild() async {
        defer {
            isRebuilding = false
            if rebuildRequestedAgain {
                rebuildRequestedAgain = false
                startBackgroundRebuild()
            }
        }
        guard let root = vaultRoot, let index else { return }
        // Walk, read and parse every note off the main actor, then apply the
        // whole result in one transaction. `LoreIndex` is Sendable (it holds
        // only a GRDB `DatabaseQueue`, which serializes its own access).
        let refreshed: [IndexRow]? = await Task.detached(priority: .utility) { () -> [IndexRow]? in
            let notes = Self.scanVault(at: root)
            do {
                try index.replaceAll(with: notes)
                return try index.all()
            } catch {
                return nil
            }
        }.value
        if let refreshed { rows = refreshed }
    }

    /// Pure, off-actor: every engine-openable file under `root`, loaded and
    /// reduced to its index payload. No index access.
    ///
    /// Files no engine claims are skipped: they stay visible in Finder and can
    /// still be opened in the fallback viewer, but there is nothing meaningful
    /// to put in a full-text index for them.
    nonisolated static func scanVault(at root: URL) -> [IndexEntry] {
        var entries: [IndexEntry] = []
        // Only components BELOW the root are ours to judge. Testing the
        // absolute path would make a vault under any dot-prefixed ancestor —
        // `~/.local/share/notes`, a `.worktrees/` checkout, a sandbox
        // container — index zero files, silently, showing an empty vault with
        // no error to explain it.
        let rootDepth = root.standardizedFileURL.pathComponents.count
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            // Skip package internals and tool directories: `.obsidian`,
            // `.git`, `.trash`, and (later) `.lore` package contents are not
            // documents in their own right.
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            if relative.contains(where: { $0.hasPrefix(".") }) { continue }
            guard let engineType = EngineRegistry.engine(for: url),
                  let engine = try? engineType.load(url) else { continue }
            // File mtime is DELIBERATELY authoritative for `updated`, and
            // supersedes markdown's frontmatter `updated:` value, which the
            // pre-M0 scan used. Two reasons: it is uniform across document
            // types (plaintext has no frontmatter to read), and the
            // frontmatter field is day-granularity, so a whole day's notes
            // tie and `ORDER BY updated DESC` sorts them arbitrarily. This
            // changes sidebar ordering for vaults where the two disagree.
            let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            var payload = engine.indexPayload
            payload.plaintext = Self.capped(payload.plaintext)
            entries.append(IndexEntry(url: url, type: engineType.identifier,
                                      payload: payload, updated: updated))
        }
        return entries
    }

    /// Upper bound on the indexed text of a single document.
    ///
    /// `scanVault` holds every loaded payload resident until `replaceAll`
    /// applies them in one transaction, so without a cap total rescan memory
    /// is the size of the vault's indexable content. That was tolerable when
    /// only `.md` was scanned; `PlainTextEngine` claims `log`, `csv` and
    /// `json`, where single files run to hundreds of megabytes. Searching the
    /// first megabyte of a giant log is the right trade — holding the whole
    /// corpus in RAM is not. Truncation affects the INDEX ONLY; nothing here
    /// touches what is written back to disk.
    nonisolated static let maxIndexedPlaintextBytes = 1_048_576

    /// Truncates to at most `maxIndexedPlaintextBytes` UTF-8 bytes, cutting on
    /// a scalar boundary so the result is never a mangled half-character.
    nonisolated static func capped(_ text: String) -> String {
        guard text.utf8.count > maxIndexedPlaintextBytes else { return text }
        var bytes = Array(text.utf8.prefix(maxIndexedPlaintextBytes))
        // Walk back to the last lead byte (anything that is not a 10xxxxxx
        // continuation). If the sequence it starts would run past the cut, the
        // scalar is incomplete — drop it whole.
        var i = bytes.count - 1
        while i >= 0, bytes[i] & 0xC0 == 0x80 { i -= 1 }
        if i >= 0 {
            let lead = bytes[i]
            let width = lead < 0x80 ? 1 : (lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4))
            if i + width > bytes.count { bytes.removeSubrange(i...) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Synchronous rescan. Kept for tests and for callers that must observe the
    /// result immediately; production paths use `startBackgroundRebuild`.
    public func rebuild() throws {
        guard let root = vaultRoot, let index else { return }
        try index.replaceAll(with: Self.scanVault(at: root))
        rows = try index.all()
    }

    public func search(_ query: String) -> [IndexRow] {
        (try? index?.search(query)) ?? []
    }

    /// Index one document after a save, without a whole-vault rescan.
    func indexDocument(_ engine: any DocumentEngine, at url: URL) throws {
        guard let index else { throw LoreError.noVault }
        let type = type(of: engine).identifier
        try index.upsert(IndexEntry(url: url, type: type,
                                    payload: engine.indexPayload, updated: Date()))
        rows = try index.all()
    }

    func removeFromIndex(_ url: URL) throws {
        guard let index else { throw LoreError.noVault }
        try index.remove(path: url)
        rows = try index.all()
    }

    /// True once a vault is active — the store's `noVault` guard.
    var hasIndex: Bool { index != nil }
}
