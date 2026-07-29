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

    // MARK: - Links

    public struct Backlink: Identifiable, Sendable {
        public let id: URL
        public let row: IndexRow
        /// The line in the source document that contains the link. Empty when
        /// the file cannot be read — context is a nicety, never a failure.
        public let context: String
    }

    public func backlinks(to url: URL) -> [Backlink] {
        coordinator.backlinkRows(to: url).map { row in
            Backlink(id: row.path, row: row, context: Self.context(in: row.path, for: url))
        }
    }

    private static func context(in source: URL, for target: URL) -> String {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return "" }
        let needle = target.deletingPathExtension().lastPathComponent.lowercased()
        for line in text.split(separator: "\n") where line.lowercased().contains(needle) {
            return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
        }
        return ""
    }

    public func unresolvedLinks(from url: URL) -> [String] {
        coordinator.unresolvedLinks(from: url)
    }

    public func resolveLink(_ rawTarget: String) -> URL? {
        coordinator.currentResolver().resolve(rawTarget)
    }

    @discardableResult
    public func openLink(_ rawTarget: String) -> Bool {
        guard let url = resolveLink(rawTarget) else { return false }
        open(url: url)
        return true
    }

    /// Documents whose title or an alias starts with `prefix`, for `[[` completion.
    public func linkCompletions(matching prefix: String) -> [IndexRow] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return Array(rows.prefix(20)) }
        return rows.filter { row in
            row.title.lowercased().hasPrefix(needle)
                || row.aliases.contains { $0.lowercased().hasPrefix(needle) }
        }
    }
    /// Releases the vault. Tabs are flushed FIRST — see `closeAllTabs` — so a
    /// teardown never costs the user unsaved work, and so the flush still has a
    /// live index to update before the coordinator drops it.
    public func shutdown() {
        closeAllTabs()
        coordinator.shutdown()
    }

    /// Flush-and-drop every open tab. The one lifecycle used by BOTH teardown
    /// and vault switching, in this exact order:
    ///
    /// 1. save every dirty, writable session — `shutdown` used to just assign
    ///    `tabs = []`, bypassing all of `closeTab`'s hardening. A conflicted
    ///    tab stays dirty indefinitely (its autosave keeps failing through
    ///    `try?`), so that was not a 500ms window: it was "the user has a
    ///    conflict banner up, the host tears the instance down, edits gone".
    /// 2. cancel pending autosaves — otherwise a debounced write lands after
    ///    the store has moved on, into a vault the user has already left.
    /// 3. clear the tab state.
    ///
    /// A save that REFUSES (external-change conflict, read-only volume) cannot
    /// be surfaced from here: this is a non-interactive teardown, and the store
    /// holds only a `PluginDocumentStore` — the host exposes no logger to it —
    /// so there is nowhere to report to. The session's own `conflict` /
    /// `lastSaveError` flags still hold the reason, but the session is about to
    /// be released. This is a known, accepted residual: a conflicted tab open
    /// at teardown keeps the ON-DISK file (the other writer's version) and
    /// loses the in-memory edit. Wiring a host logger through would let us at
    /// least record it, and is the right M1 follow-up.
    private func closeAllTabs() {
        for tab in tabs {
            if tab.isDirty && !tab.isReadOnly {
                try? tab.saveNow()
            }
            tab.cancelPendingSave()
        }
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
        // Past this point the tab IS being removed, on both the normal and the
        // forced path, so the debounced autosave must be disarmed: it would
        // otherwise fire into a document nobody owns any more — writing back
        // edits the user chose to discard, or resurrecting a file a delete is
        // about to unlink.
        session.cancelPendingSave()
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

    /// Switching vaults is a teardown of the old one, not just a new root:
    /// tabs, selection and `openError` all point INTO the previous vault, and
    /// left alone they keep autosaving into vault A while the user is looking
    /// at vault B. Same lifecycle as `shutdown`.
    public func setVaultRoot(_ url: URL) throws {
        try VaultBookmark.save(url, to: documents)
        closeAllTabs()
        try coordinator.activate(root: url)
    }

    /// Test seam: activate without a security-scoped bookmark. Performs the
    /// same tab teardown as `setVaultRoot`, so tests exercise the real switch.
    func setVaultRootForTesting(_ url: URL) throws {
        closeAllTabs()
        try coordinator.activate(root: url)
    }

    // MARK: - Documents
    //
    // `load` and `save` stay here deliberately: Task 7 did NOT take them, and
    // Task 10 kept them because the MCP note tools are their only remaining
    // callers (the UI goes through `DocumentSession`). M6 owns the redesign
    // that decides where note-level read/write really belongs.

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
