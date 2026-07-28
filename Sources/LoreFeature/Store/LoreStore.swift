import Foundation
import Observation
import AinkradAppKit

@MainActor
@Observable
public final class LoreStore {
    public private(set) var rows: [IndexRow] = []
    public private(set) var vaultRoot: URL?
    /// Relative subfolder (under the vault root) where ⌘N quick-capture writes
    /// new notes. Empty string == the vault root itself.
    public private(set) var defaultNoteFolder: String = ""

    private let documents: PluginDocumentStore
    private let indexPath: URL
    private var index: LoreIndex?
    private var watcher: FolderWatcher?
    private var openMTimes: [URL: Date] = [:]
    /// While `Date() < suppressWatcherUntil`, `FolderWatcher` callbacks are
    /// ignored — see `save(_:overwritingExternalChanges:)`.
    private var suppressWatcherUntil: Date = .distantPast
    /// A background rescan is in flight.
    private var isRebuilding = false
    /// A vault change arrived while a rescan was running — run once more after.
    private var rebuildRequestedAgain = false

    private static let defaultFolderKey = "defaultNoteFolder"
    /// How long after our own write a watcher event is treated as the echo of
    /// that write. Generous enough to cover FSEvents' coalescing latency,
    /// short enough that a genuine external edit arriving right after a save
    /// is still picked up on the next event.
    private static let selfWriteSuppressionWindow: TimeInterval = 1.0

    public init(documents: PluginDocumentStore, indexPath: URL) {
        self.documents = documents
        self.indexPath = indexPath
        if let data = documents.data(forKey: Self.defaultFolderKey),
           let folder = String(data: data, encoding: .utf8) {
            defaultNoteFolder = folder
        }
        if let root = VaultBookmark.resolve(from: documents) {
            try? activate(root: root)
        }
    }

    /// Every distinct tag across all indexed notes, sorted — drives the sidebar
    /// tag-filter chips.
    public var allTags: [String] { Array(Set(rows.flatMap(\.tags))).sorted() }

    /// Immediate subdirectories of the vault root (dotfiles excluded) — the
    /// choices offered for `defaultNoteFolder` in Settings.
    public var subfolders: [String] {
        guard let root = vaultRoot else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Persist the default new-note subfolder (relative to the vault root).
    public func setDefaultNoteFolder(_ relative: String) {
        defaultNoteFolder = relative
        documents.setData(relative.data(using: .utf8), forKey: Self.defaultFolderKey)
    }

    public func setVaultRoot(_ url: URL) throws {
        try VaultBookmark.save(url, to: documents)
        try activate(root: url)
    }

    /// Test seam: activate without a security-scoped bookmark.
    func setVaultRootForTesting(_ url: URL) throws { try activate(root: url) }

    private func activate(root: URL) throws {
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

    /// Pure, off-actor: every `.md` under `root`, parsed. No index access.
    nonisolated static func scanVault(at root: URL) -> [Note] {
        var notes: [Note] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            notes.append(Frontmatter.parse(text, path: url))
        }
        return notes
    }

    /// Synchronous rescan. Kept for tests and for callers that must observe the
    /// result immediately; production paths use `startBackgroundRebuild`.
    public func rebuild() throws {
        guard let root = vaultRoot, let index else { return }
        try index.replaceAll(with: Self.scanVault(at: root))
        rows = try index.all()
    }

    public func load(_ row: IndexRow) throws -> Note {
        let text = try String(contentsOf: row.path, encoding: .utf8)
        let note = Frontmatter.parse(text, path: row.path)
        openMTimes[row.path] = try mtime(of: row.path)
        return note
    }

    @discardableResult
    public func create(title: String) throws -> Note {
        guard let root = vaultRoot, let index else { throw LoreError.noVault }
        let slug = title.isEmpty ? "untitled" : title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let dir = defaultNoteFolder.isEmpty
            ? root : root.appendingPathComponent(defaultNoteFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, slug: slug)
        let now = Date()
        let note = Note(path: url, id: UUID().uuidString, title: title, tags: [],
                        created: now, updated: now, body: "")
        try Frontmatter.serialize(note).write(to: url, atomically: true, encoding: .utf8)
        try index.upsert(note)
        rows = try index.all()
        openMTimes[url] = try mtime(of: url)
        return note
    }

    /// Writes `note` back to its file.
    ///
    /// Refuses when the file changed on disk since it was loaded, unless
    /// `overwritingExternalChanges` is set. `externalChangeDetected(for:)`
    /// already existed and was already correct — `save` simply never consulted
    /// it. So an edit made in Obsidian (or by the agent's `edit_file`, or by a
    /// sync client) while a note sat open in Lore's editor was destroyed by the
    /// editor's next 500ms autosave: silently, with no diff and no undo. That
    /// is a note-taking app losing notes.
    ///
    /// Detection is mtime-based and therefore best-effort — a write inside the
    /// filesystem's timestamp granularity can still slip through. A much
    /// smaller hole than not checking at all.
    public func save(_ note: Note, overwritingExternalChanges: Bool = false) throws {
        guard let index else { throw LoreError.noVault }
        if !overwritingExternalChanges, externalChangeDetected(for: note) {
            throw LoreError.externalChange(note.path)
        }
        var updated = note; updated.updated = Date()

        // Suppress the watcher across our own write. Saving fires
        // `FolderWatcher`, whose handler is a FULL `rebuild()` — re-reading and
        // re-indexing every markdown file in the vault, on the main actor, in
        // response to our own single-file write. On a large vault every
        // autosave stalled the editor mid-keystroke.
        suppressWatcherUntil = Date().addingTimeInterval(Self.selfWriteSuppressionWindow)

        try Frontmatter.serialize(updated).write(to: note.path, atomically: true, encoding: .utf8)
        try index.upsert(updated)
        rows = try index.all()
        openMTimes[note.path] = try mtime(of: note.path)
    }

    public func delete(_ row: IndexRow) throws {
        guard let index else { throw LoreError.noVault }
        try? FileManager.default.removeItem(at: row.path)
        try index.remove(path: row.path)
        openMTimes[row.path] = nil
        rows = try index.all()
    }

    public func search(_ query: String) -> [IndexRow] {
        (try? index?.search(query)) ?? []
    }

    /// True if the file changed on disk since we last loaded/saved it.
    public func externalChangeDetected(for note: Note) -> Bool {
        guard let known = openMTimes[note.path], let disk = try? mtime(of: note.path) else { return false }
        return disk > known
    }

    private func mtime(of url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? .distantPast
    }

    private func uniqueURL(in root: URL, slug: String) -> URL {
        var candidate = root.appendingPathComponent("\(slug).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(slug)-\(n).md"); n += 1
        }
        return candidate
    }
}

public enum LoreError: Error, Equatable {
    case noVault
    /// The note's file changed on disk since it was loaded. Saving would
    /// discard those changes, so the caller must decide: reload, or overwrite
    /// via `save(_:overwritingExternalChanges: true)`.
    case externalChange(URL)
}
