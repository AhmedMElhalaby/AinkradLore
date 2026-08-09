import SwiftUI
import AinkradAppKit

struct LoreRootView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @State private var query = ""
    @State private var selected: IndexRow?
    @State private var activeTag: String?
    /// The file the user most recently asked to open. `LoreStore.openError` is
    /// only cleared by the next SUCCESSFUL open, so it can outlive the click
    /// that produced it; gating the fallback viewer on this makes sure a stale
    /// error never shadows a document that opened perfectly well.
    @State private var attempted: URL?
    /// Rename / move / trash for both sidebar modes. Created here so the two
    /// sidebars share one state machine and one set of modals.
    @State private var ops: SidebarOperations

    init(store: LoreStore, theme: HostTheme) {
        self.store = store
        self.theme = theme
        _ops = State(initialValue: SidebarOperations(store: store))
    }

    /// A filtered tree of mostly-empty branches is worse than a list, so an
    /// active search or tag filter always wins over the persisted tree
    /// preference — the tree is only shown when nothing is filtering it.
    private var effectiveSidebarMode: LoreStore.SidebarMode {
        (query.isEmpty && activeTag == nil) ? store.sidebarMode : .all
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                // Search and quick-capture live ABOVE the mode picker, outside
                // both sidebars. They used to live inside `NoteListView`, which
                // is not mounted in tree mode — so in tree mode the user could
                // not search and could not create a note at all. Typing a query
                // still swings the sidebar to the flat list (see
                // `effectiveSidebarMode`); the point is that the field exists to
                // type into either way.
                HStack(spacing: AinkradSpacing.sm) {
                    AinkradSearchField(text: $query, placeholder: "Search notes")
                    // Folder creation belongs to Folders mode only — "All
                    // notes" (`NoteListView`) has no folder affordances at
                    // all, by design. Gated on `effectiveSidebarMode` rather
                    // than `store.sidebarMode` so an active search/tag filter
                    // (which silently forces the flat list — see
                    // `effectiveSidebarMode`) hides this too: it would
                    // otherwise sit above a list that is not the tree, next to
                    // rows it cannot affect.
                    if effectiveSidebarMode == .tree, let root = store.vaultRoot {
                        AinkradIconButton(systemName: "folder.badge.plus",
                                         tooltip: "New Folder") {
                            ops.beginNewFolder(in: root)
                        }
                    }
                    AinkradIconButton(systemName: "plus", action: quickCapture)
                        .keyboardShortcut("n", modifiers: .command)
                }
                .padding(.horizontal, AinkradSpacing.md)
                .padding(.top, AinkradSpacing.md)

                AinkradSegmentedPicker(
                    items: [LoreStore.SidebarMode.tree, .all],
                    selection: Binding(get: { store.sidebarMode },
                                       set: { store.setSidebarMode($0) })
                ) { mode in mode == .tree ? "Folders" : "All notes" }
                .padding(.horizontal, AinkradSpacing.md)

                if effectiveSidebarMode == .tree {
                    FolderTreeView(store: store, theme: theme, selected: $selected,
                                  onSelect: openRow, ops: ops)
                } else {
                    NoteListView(store: store, query: $query, selected: $selected, theme: theme,
                                onSelect: openRow, onNew: quickCapture, ops: ops,
                                activeTag: $activeTag)
                }
            }
                .frame(width: 280)
            VStack(spacing: 0) {
                if !store.tabs.isEmpty {
                    TabBarView(store: store, theme: theme,
                               onSelect: { _ in attempted = nil })
                }
                content
            }
        }
        .background(theme.tokens.background)
        .environment(\.ainkradTheme, theme.tokens)
        // Attached at the surface ROOT: `ainkradConfirmDialog` dims and centers
        // within the view it modifies, so attaching it to the 280pt sidebar
        // would scope a destructive confirmation to a narrow column.
        .loreSidebarOperations(ops, theme: theme)
        // A rename, a move or a delete makes a held `IndexRow` stale — its path
        // no longer names a file. Dropped when the row set changes, so the
        // sidebar cannot keep a selection pointing at something that is gone
        // (and `content` cannot keep showing a fallback for it).
        .onChange(of: store.rows.count) { _, _ in
            if let row = selected, !store.rows.contains(where: { $0.path == row.path }) {
                selected = nil
            }
            if let url = attempted, !store.rows.contains(where: { $0.path == url }) {
                attempted = nil
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let failure = store.openError, failure.url == attempted {
            DocumentErrorCard(url: failure.url,
                              message: "Lore couldn't open this document.",
                              theme: theme)
        } else if let session = store.selectedTab {
            // Identity is the session's stable id — NOT its url, which changes
            // when the session adopts a "save a copy" resolution.
            DocumentPane(store: store, session: session, theme: theme)
                .id(session.id)
        } else {
            switch Self.emptyState(for: store) {
            case .noVault:
                // Offering "New note" here was the whole bug: with no vault the
                // click could not succeed, and the copy told the user to press
                // ⌘N — advice guaranteed to do nothing. The first-run state has
                // exactly one useful action, so it is the only one offered.
                AinkradEmptyState(
                    icon: "folder.badge.questionmark",
                    title: "No vault open",
                    message: "Lore keeps your notes in a folder on disk. "
                        + "Choose the folder that holds them to get started.",
                    actionTitle: "Choose vault…",
                    action: ops.beginChooseVault)
            case .noDocument:
                AinkradEmptyState(
                    icon: "book.closed",
                    title: "No document open",
                    message: "Select a document from the list, or press ⌘N to capture a new one.",
                    actionTitle: "New note",
                    action: quickCapture)
            }
        }
    }

    /// Which empty state the pane is in.
    ///
    /// A `static` on the view, not a computed property, because SwiftUI views
    /// are only smoke-testable in this project — this is the value the branch
    /// above is built from, and `NoVaultTests` asserts it directly.
    enum EmptyState: Equatable { case noVault, noDocument }

    static func emptyState(for store: LoreStore) -> EmptyState {
        store.vaultRoot == nil ? .noVault : .noDocument
    }

    private func openRow(_ row: IndexRow) {
        selected = row
        attempted = row.path
        store.open(row)
    }

    /// Create-and-open. The failure path goes through `ops.message` rather than
    /// `try?` — see `SidebarOperations.createDocument`, which is where the
    /// reason for the failure is turned into a sentence.
    private func quickCapture() {
        guard let path = ops.createDocument() else { return }
        attempted = path
        store.open(url: path)
        selected = store.rows.first { $0.path == path }
    }
}

/// Testable core of the list's delete affordance (which moved off the old
/// `NoteEditorPane` when that view was deleted).
///
/// Goes through `store.trash(_:)`, which owns the whole destructive sequence:
/// flushing or REFUSING on a tab with unsaved edits, cancelling the debounced
/// autosave (which would otherwise recreate the file the user just deleted),
/// closing the tab, moving the file to the Trash rather than unlinking it, and
/// dropping it from the index.
///
/// This function used to do the tab handling itself, matching `$0.url ==
/// row.path` — a raw-versus-canonical comparison that silently found nothing
/// for a tab opened with a non-canonical URL, leaving exactly the resurrection
/// defect `trash` was written to close. It has no business owning that logic
/// twice.
///
/// RETURNS the refusal rather than swallowing it, and nil on success.
///
/// This was `try? store.trash(row)`. `trash` REFUSES when an open tab still
/// holds unsaved edits it could not flush — so the user pressed Delete, the file
/// stayed, and nothing said why: a silent no-op indistinguishable from a broken
/// button. `trashFailed` (a volume with no `.Trashes`) was equally invisible.
/// `SidebarOperations.confirmTrash` puts the returned sentence in front of the
/// user, and the sentence for `unsavedEdits` carries the way out.
@MainActor
@discardableResult
func deleteDocument(_ row: IndexRow, in store: LoreStore) -> String? {
    do {
        _ = try store.trash(row)
        return nil
    } catch let error as LoreError {
        return SidebarOperations.describe(error, row: row)
    } catch {
        return "“\(row.path.lastPathComponent)” could not be moved to the Trash: "
            + error.localizedDescription
    }
}
