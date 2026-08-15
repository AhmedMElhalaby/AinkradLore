import Foundation
import Observation
import AinkradAppKit

@MainActor
@Observable
public final class LoreStore {
    // Persisted preferences are `internal(set)`, not `private(set)`: their
    // setters live in `LoreStore+Preferences.swift` and `private(set)` is
    // file-scoped. All are plain stored values with no `didSet` and no
    // invariant to guard, and the setters remain their only writers.

    /// Relative subfolder (under the vault root) where ⌘N quick-capture writes
    /// new notes. Empty string == the vault root itself.
    public internal(set) var defaultNoteFolder: String = ""

    /// Sidebar layout choice: folder tree or the flat, searchable list.
    public enum SidebarMode: String, Sendable { case tree, all }

    public internal(set) var sidebarMode: SidebarMode = .tree
    /// Folder ids (relative paths under the vault root) currently expanded in
    /// `FolderTreeView`. Persisted so returning to a vault restores the tree
    /// the user left open, rather than collapsing everything.
    public internal(set) var expandedFolders: Set<String> = []

    /// Whether `BacklinksPanel` is expanded or collapsed, persisted the same
    /// way as `sidebarMode`: a per-vault-host UI choice, not per-document, so
    /// one toggle sticks across every note the user opens.
    public internal(set) var backlinksPanelExpanded: Bool = true

    /// Whether `OutlineSection` is expanded or collapsed. Same shape and same
    /// reasoning as `backlinksPanelExpanded`.
    public internal(set) var outlinePanelExpanded: Bool = true

    /// "Show all files" — OFF by default, so a non-document attachment (a
    /// `.zip`, a stray binary, an OAuth credentials file) is hidden from the
    /// sidebar browse lists (`FolderTreeView`, `NoteListView`) unless the
    /// owner opts in. See `DocumentVisibility` for what "hidden" does and
    /// does not mean — it is a browse-list filter only, never an indexing or
    /// resolution decision.
    public internal(set) var showAllFiles: Bool = false

    /// Whether the sidebar is hidden. Persisted the same way as `sidebarMode`:
    /// a per-vault-host UI choice, not per-document.
    public internal(set) var sidebarCollapsed: Bool = false

    /// Sidebar width in points, persisted like the other layout choices.
    ///
    /// Clamped on read as well as on write: the stored value comes from a
    /// file a user can edit, and a 4000pt sidebar would leave no editor at all
    /// with no way to drag it back.
    public internal(set) var sidebarWidth: CGFloat = LoreMetrics.defaultSidebarWidth

    /// The reader's preferences for the writing surface — see `EditorSettings`
    /// for why the editor owns these rather than inheriting them from the host
    /// theme.
    public internal(set) var editorSettings: EditorSettings = .default

    /// The one file `trash(_:)` most recently moved to the Trash, and where
    /// macOS put it — the whole of what `undoTrash()` needs to put it back.
    ///
    /// ONE deep, deliberately. This is the undo behind a toast that lives for
    /// three seconds, not a general undo stack: the honest scope of "you just
    /// did that, take it back" is the last action, and a deeper stack would
    /// imply a history the UI does not show and cannot be trusted to still be
    /// valid (every entry is a path on disk that anything else may have moved
    /// in the meantime).
    ///
    /// Nil whenever there is nothing to undo — including after a successful
    /// undo, so the same record can never be replayed twice.
    /// `internal(set)`, not `private(set)`: `trash(_:)` and `undoTrash()` live
    /// in `LoreStore+Trash.swift`, and Swift's `private(set)` is file-scoped.
    /// Still closed to callers outside the module, which is the access this
    /// property actually needs.
    public internal(set) var lastTrash: TrashUndo?

    /// Everything needed to reverse one `trash(_:)`.
    public struct TrashUndo: Equatable, Sendable {
        /// Where the file lived in the vault, CANONICAL — the same spelling
        /// `trash` removed from the index, so the restore re-indexes under a
        /// path that matches.
        public let original: URL
        /// Where macOS actually put it, from `trashItem`'s
        /// `resultingItemURL`. Lore used to pass `nil` here and throw this
        /// away, which is the only reason undo looked expensive.
        public let trashed: URL
        /// What to call the file in the toast.
        public let name: String
    }

    /// Internal, not private: the persisted-preference setters live in
    /// `LoreStore+Preferences.swift`, and Swift's `private` is file-scoped.
    /// Still closed outside the module.
    let documents: PluginDocumentStore
    /// Internal, not private, so `LoreStore+Rename.swift` can reach the index.
    /// The rename applier lives in its own file to keep this one under the
    /// 500-line ceiling.
    let coordinator: VaultIndexCoordinator
    /// mtime baselines for the legacy note API, keyed by CANONICAL path string
    /// (`pathKey`), never by a raw `URL`.
    ///
    /// Keyed raw, `transferOpenMTime` — which both `apply` paths call with
    /// CANONICAL URLs — found no entry for a note whose baseline had been stored
    /// under the caller's raw `note.path`, silently no-opped, and left
    /// `externalChangeDetected(for:)` with no baseline. That returns `false`,
    /// which turns `save`'s external-change guard OFF for exactly the note that
    /// was just renamed: precisely the data loss `transferOpenMTime`'s own doc
    /// comment says it exists to prevent. One key function on both sides is what
    /// makes that unrepresentable.
    /// Internal, not private: `LoreStore+Documents.swift` — `load`, `create`,
    /// `save` and the mtime bookkeeping around them — reads and writes it,
    /// and Swift has no cross-file `private`.
    var openMTimes: [String: Date] = [:]

    public init(documents: PluginDocumentStore, indexPath: URL) {
        self.documents = documents
        self.coordinator = VaultIndexCoordinator(indexPath: indexPath)
        if let data = documents.data(forKey: Self.defaultFolderKey),
           let folder = String(data: data, encoding: .utf8) {
            defaultNoteFolder = folder
        }
        if let data = documents.data(forKey: Self.sidebarModeKey),
           let raw = String(data: data, encoding: .utf8),
           let mode = SidebarMode(rawValue: raw) {
            sidebarMode = mode
        }
        if let data = documents.data(forKey: Self.expandedFoldersKey),
           let text = String(data: data, encoding: .utf8) {
            expandedFolders = Set(text.split(separator: "\n").map(String.init))
        }
        if let data = documents.data(forKey: Self.backlinksPanelExpandedKey),
           let raw = String(data: data, encoding: .utf8) {
            backlinksPanelExpanded = raw == "true"
        }
        if let data = documents.data(forKey: Self.outlinePanelExpandedKey),
           let raw = String(data: data, encoding: .utf8) {
            outlinePanelExpanded = raw == "true"
        }
        if let data = documents.data(forKey: Self.showAllFilesKey),
           let raw = String(data: data, encoding: .utf8) {
            showAllFiles = raw == "true"
        }
        if let data = documents.data(forKey: Self.sidebarCollapsedKey),
           let text = String(data: data, encoding: .utf8) {
            sidebarCollapsed = (text == "1")
        }
        // Decoded leniently: a settings blob written by a NEWER Lore (or a
        // corrupt one) falls back to the defaults rather than refusing to
        // start. Preferences are not worth failing a launch over.
        if let data = documents.data(forKey: Self.editorSettingsKey),
           let decoded = try? JSONDecoder().decode(EditorSettings.self, from: data) {
            editorSettings = decoded
        }
        if let data = documents.data(forKey: Self.sidebarWidthKey),
           let text = String(data: data, encoding: .utf8), let width = Double(text) {
            // Clamped on READ too — the stored value comes from a file a user
            // can edit, and a 4000pt sidebar leaves no editor and no grip to
            // drag back with.
            sidebarWidth = LoreMetrics.clampSidebarWidth(CGFloat(width))
        }
        if let root = VaultBookmark.resolve(from: documents) {
            try? coordinator.activate(root: root)
        }
    }

    // MARK: - Index facade

    public var rows: [IndexRow] { coordinator.rows }
    public var vaultRoot: URL? { coordinator.vaultRoot }
    /// Vault-relative paths of every directory — see
    /// `VaultIndexCoordinator.directoryPaths`'s doc comment. `FolderTreeView`
    /// reads this (not a filesystem walk of its own) to show empty folders.
    var directoryPaths: [String] { coordinator.directoryPaths }
    public func search(_ query: String) -> [IndexRow] { coordinator.search(query) }

    /// Search results carrying the matched excerpt — see `SearchSnippet`.
    public func searchHits(_ query: String) -> [SearchHit] { coordinator.searchHits(query) }
    /// Whether `undoTrash()` currently has a delete to reverse.
    public var canUndoTrash: Bool { lastTrash != nil }

    public func rebuild() throws { try coordinator.rebuild() }

    /// True while a vault rescan is running — drives the sidebar's "Indexing…"
    /// state and the Settings spinner.
    public var isIndexing: Bool { coordinator.isRebuilding }

    /// Why the last rescan failed, or nil. Used to be discarded entirely.
    public var indexError: String? { coordinator.lastRebuildError }

    /// Rescan the vault WITHOUT blocking the main actor.
    ///
    /// The Settings button used to call `try? rebuild()` — the synchronous
    /// path — which walks, reads and parses every file on the main actor: a
    /// multi-second freeze with no spinner and, thanks to the `try?`, no
    /// report of a failure. Same background path a vault change already takes;
    /// synchronous `rebuild()` stays for tests and callers that must observe
    /// the result immediately.
    public func rebuildInBackground() { coordinator.startBackgroundRebuild() }

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

    /// `url`'s path relative to `root`, as a plain STRING prefix strip —
    /// `"Parent/Q1"` for `<root>/Parent/Q1`. Deliberately NOT
    /// `pathComponents.dropFirst(rootDepth)`: that shape (used by
    /// `createFolder`/`applyTrashFolder`/folder-rename `apply` in earlier
    /// drafts of this exact computation) reads `root.standardizedFileURL
    /// .pathComponents.count` and `url.standardizedFileURL.pathComponents`
    /// SEPARATELY, and `standardizedFileURL` on macOS inconsistently
    /// collapses a `/private/var/…` prefix to `/var/…` depending on the
    /// URL's OWN depth — confirmed by direct measurement: `root` alone
    /// standardized to 7 components (`private` dropped), the same root with
    /// one more path component appended standardized to 9 (`private` kept).
    /// The two counts then silently disagreed by exactly one component,
    /// which strips one component too few or too many depending on
    /// direction — the round-4 bug (`directoryPaths` after a real trash/
    /// rename computed a garbage vault-"relative" path that still had the
    /// system temp directory's own name in it, so it never matched anything
    /// already in `directoryPaths` and the removal/rename silently no-opped).
    /// A raw string-prefix strip on `.path` has no such inconsistency: both
    /// `url` and `root` are expected to already be canonical (realpath'd via
    /// `VaultIndexCoordinator.canonical`, or built by literally appending
    /// path components to an already-canonical root, as `createFolder`'s
    /// `destination` and `FolderTreeView.folderURL` both do) — same spelling
    /// in, same spelling out, no re-interpretation in between.
    static func vaultRelativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(url.path.dropFirst(rootPath.count))
    }

    public func unresolvedLinks(from url: URL) -> [UnresolvedLink] {
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
        // History outlives no vault: its URLs point into the one being closed.
        history = []
        historyIndex = nil
    }
    func settleForTesting() async { await coordinator.settleForTesting() }
    func handleVaultChange() { coordinator.handleVaultChange() }
    func startBackgroundRebuild() { coordinator.startBackgroundRebuild() }

    // MARK: - Tabs

    public internal(set) var tabs: [DocumentSession] = []
    public internal(set) var selectedTab: DocumentSession?
    /// Set when the last open attempt failed. The UI renders the fallback
    /// viewer from this rather than silently doing nothing — a file the list
    /// shows must always produce a visible response when clicked.
    public private(set) var openError: (url: URL, error: Error)?

    public func open(_ row: IndexRow) { open(url: row.path) }

    public func open(url: URL) {
        open(url: url, recordingHistory: true)
    }

    /// Opens `url`, optionally without recording the visit.
    ///
    /// `recordingHistory: false` is what `goBack()`/`goForward()` use: moving
    /// through history is not itself a new visit, and recording it would make
    /// Back push an entry that Forward then has to step over — a stack that
    /// grows every time you use it and never returns you where you started.
    func open(url: URL, recordingHistory: Bool) {
        // Canonical on both sides. Compared raw, opening the already-open
        // `/tmp/v/a.md` as `/private/tmp/v/a.md` (or via a canonical `row.path`)
        // produced a SECOND session on the same file, each with its own mtime
        // baseline and its own debounced autosave racing the other.
        if let existing = tabs.first(where: { Self.pathKey($0.url) == Self.pathKey(url) }) {
            touch(existing)
            selectedTab = existing
            if recordingHistory { recordVisit(existing.url) }
            return
        }
        do {
            let session = try DocumentSession.open(url: url, coordinator: coordinator)
            tabs.append(session)
            selectedTab = session
            openError = nil
            if recordingHistory { recordVisit(session.url) }
            evictColdSessions()
        } catch {
            openError = (url, error)
        }
    }

    public func selectTab(_ session: DocumentSession) {
        touch(session)
        selectedTab = session
        recordVisit(session.url)
    }

    // MARK: - History

    /// Documents visited, oldest first — the back/forward stack.
    ///
    /// Replaces the tab strip's job of "get me back to what I was just
    /// looking at". In a vault, that is almost always a LINEAR trail (follow a
    /// link, read, come back), which a stack models exactly and a strip models
    /// only by accident of ordering.
    public internal(set) var history: [URL] = []
    /// Where in `history` the open document sits. Nil before anything opens.
    public internal(set) var historyIndex: Int?

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
            // The most recently used document, which `tabs`' LRU ordering puts
            // last. This used to pick the closed tab's NEIGHBOUR, which was
            // right when `tabs` was a visible strip (the eye expects the gap to
            // close sideways) and is wrong now that it is a cache: adjacency in
            // a cache is meaningless, and "what I was looking at before this
            // one" is the only answer a user can predict.
            selectedTab = tabs.last
        }
        return true
    }

    /// Every distinct tag across all indexed notes, sorted — drives the sidebar
    /// tag-filter chips.
    public var allTags: [String] { Array(Set(rows.flatMap(\.tags))).sorted() }

    /// How many notes carry each tag.
    ///
    /// Computed with `allTags` rather than separately: both walk every row's
    /// tag list, and the chip row reads them together on the same render.
    public var tagCounts: [String: Int] {
        rows.reduce(into: [:]) { counts, row in
            for tag in row.tags { counts[tag, default: 0] += 1 }
        }
    }

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

    // `load`, `create`, `save` and the mtime bookkeeping around them live in
    // `LoreStore+Documents.swift`, following this file's extension
    // convention (`LoreStore+Folders.swift`, `LoreStore+Trash.swift`, …).
}

public enum LoreError: Error, Equatable {
    case noVault
    /// The note's file changed on disk since it was loaded. Saving would
    /// discard those changes, so the caller must decide: reload, or overwrite
    /// via `save(_:overwritingExternalChanges: true)`.
    case externalChange(URL)
    /// `FileManager.trashItem` failed for the given URL (network volume,
    /// external drive with no `.Trashes`, permissions, …). NEVER silently
    /// falls back to `removeItem` — see `LoreStore+Trash.swift`.
    case trashFailed(URL, String)
    /// An open tab still holds unsaved edits to this file, and flushing them
    /// refused, so the operation was declined rather than performed over text
    /// the user has never seen saved. The `String` is a reason phrase naming
    /// the unsaved edits and how to clear them — see `LoreStore.trash`.
    case unsavedEdits(URL, String)
    /// A write would have landed outside the vault root — reached only via a
    /// folder name taken from untrusted document text (a `[[a/b]]` link),
    /// where a symlink inside the vault redirects the path out of it.
    case outsideVault(URL)
    /// `createFolder`'s name is not a single path COMPONENT — empty, a
    /// separator, `:`, `.` or `..` — and is REJECTED rather than sanitized: a
    /// silently-renamed folder is worse than a refused one, because the user
    /// asked for a specific name and would not know they did not get it.
    case invalidName(String)
    /// `createFolder`'s destination already exists.
    case alreadyExists(URL)
    /// `writeAttachment(copying:besideNote:)` was handed something other
    /// than a regular file (or a symlink resolving to one) — a directory,
    /// most commonly a Finder folder dropped where an attachment was
    /// expected. `copyItem` has no size bound on a directory and would
    /// recurse the whole subtree synchronously on the main actor, so this
    /// is refused before any bytes move rather than left to beachball.
    case notARegularFile(URL)
    /// `undoTrash()` was asked to restore a file to a path that is occupied
    /// again — the user trashed `Q1.md` and then made a new `Q1.md`. REFUSED
    /// rather than overwritten: the undo exists to recover a file, and a
    /// version of it that destroys a newer one on the way is not a recovery.
    case restoreBlocked(URL)
    /// `undoTrash()` could not move the file back out of the Trash (the user
    /// emptied it, or moved the item by hand). The `String` carries the
    /// underlying reason.
    case restoreFailed(URL, String)
}
