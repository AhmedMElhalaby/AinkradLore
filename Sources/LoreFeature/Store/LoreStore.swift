import Foundation
import Observation
import AinkradAppKit

@MainActor
@Observable
public final class LoreStore {
    /// Relative subfolder (under the vault root) where ⌘N quick-capture writes
    /// new notes. Empty string == the vault root itself.
    public private(set) var defaultNoteFolder: String = ""

    private let documents: PluginDocumentStore
    private let coordinator: VaultIndexCoordinator
    private var openMTimes: [URL: Date] = [:]

    private static let defaultFolderKey = "defaultNoteFolder"

    public init(documents: PluginDocumentStore, indexPath: URL) {
        self.documents = documents
        self.coordinator = VaultIndexCoordinator(indexPath: indexPath)
        if let data = documents.data(forKey: Self.defaultFolderKey),
           let folder = String(data: data, encoding: .utf8) {
            defaultNoteFolder = folder
        }
        if let root = VaultBookmark.resolve(from: documents) {
            try? coordinator.activate(root: root)
        }
    }

    // MARK: - Index facade

    public var rows: [IndexRow] { coordinator.rows }
    public var vaultRoot: URL? { coordinator.vaultRoot }
    public func search(_ query: String) -> [IndexRow] { coordinator.search(query) }
    public func rebuild() throws { try coordinator.rebuild() }
    public func shutdown() {
        coordinator.shutdown()
        tabs = []
        selectedTab = nil
        openError = nil
    }
    func settleForTesting() async { await coordinator.settleForTesting() }
    func handleVaultChange() { coordinator.handleVaultChange() }
    func startBackgroundRebuild() { coordinator.startBackgroundRebuild() }

    // MARK: - Tabs

    public private(set) var tabs: [DocumentSession] = []
    public private(set) var selectedTab: DocumentSession?
    /// Set when the last open attempt failed. The UI renders the fallback
    /// viewer from this rather than silently doing nothing — a file the list
    /// shows must always produce a visible response when clicked.
    public private(set) var openError: (url: URL, error: Error)?

    public func open(_ row: IndexRow) { open(url: row.path) }

    public func open(url: URL) {
        if let existing = tabs.first(where: { $0.url == url }) {
            selectedTab = existing
            return
        }
        do {
            let session = try DocumentSession.open(url: url, coordinator: coordinator)
            tabs.append(session)
            selectedTab = session
            openError = nil
        } catch {
            openError = (url, error)
        }
    }

    public func selectTab(_ session: DocumentSession) { selectedTab = session }

    /// Closing does NOT discard unsaved edits: `DocumentSession` autosaves on a
    /// 500ms debounce, so a tab closed immediately after a keystroke could
    /// otherwise lose that edit. A read-only session can never be dirty (see
    /// `DocumentSession.markChanged`), so this only ever writes a document the
    /// engine can actually save.
    ///
    /// A `false` return means the document still has unsaved work and is
    /// still open: the tab was NOT removed, its selection was left
    /// untouched, and the session's own `conflict` / `lastSaveError` flags
    /// already explain why (a real save failure, or an external change).
    /// Callers must not assume a `false` return means the tab is gone.
    /// Pass `force: true` to remove the tab regardless — the user explicitly
    /// choosing to discard.
    @discardableResult
    public func closeTab(_ session: DocumentSession, force: Bool = false) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0 === session }) else { return false }
        if session.isDirty && !session.isReadOnly {
            do {
                try session.saveNow()
            } catch {
                if !force { return false }
            }
        }
        tabs.remove(at: idx)
        if selectedTab === session {
            selectedTab = tabs.indices.contains(idx) ? tabs[idx]
                        : tabs.indices.contains(idx - 1) ? tabs[idx - 1]
                        : tabs.last
        }
        return true
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
        try coordinator.activate(root: url)
    }

    /// Test seam: activate without a security-scoped bookmark.
    func setVaultRootForTesting(_ url: URL) throws { try coordinator.activate(root: url) }

    // MARK: - Documents
    //
    // `load` and `save` stay here until Task 7 moves them to `DocumentSession`
    // so the MCP layer keeps compiling.

    public func load(_ row: IndexRow) throws -> Note {
        let text = try String(contentsOf: row.path, encoding: .utf8)
        let note = Frontmatter.parse(text, path: row.path)
        openMTimes[row.path] = try mtime(of: row.path)
        return note
    }

    @discardableResult
    public func create(title: String) throws -> Note {
        guard let root = vaultRoot, coordinator.hasIndex else { throw LoreError.noVault }
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
        try coordinator.indexDocument(MarkdownEngine.load(url), at: url)
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
        guard coordinator.hasIndex else { throw LoreError.noVault }
        if !overwritingExternalChanges, externalChangeDetected(for: note) {
            throw LoreError.externalChange(note.path)
        }
        var updated = note; updated.updated = Date()

        // Suppress the watcher across our own write. Saving fires
        // `FolderWatcher`, whose handler is a FULL `rebuild()` — re-reading and
        // re-indexing every markdown file in the vault, on the main actor, in
        // response to our own single-file write. On a large vault every
        // autosave stalled the editor mid-keystroke.
        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)

        try Frontmatter.serialize(updated).write(to: note.path, atomically: true, encoding: .utf8)
        try coordinator.indexDocument(MarkdownEngine.load(note.path), at: note.path)
        openMTimes[note.path] = try mtime(of: note.path)
    }

    public func delete(_ row: IndexRow) throws {
        guard coordinator.hasIndex else { throw LoreError.noVault }
        try? FileManager.default.removeItem(at: row.path)
        try coordinator.removeFromIndex(row.path)
        openMTimes[row.path] = nil
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
