import SwiftUI
import AinkradAppKit

struct NoteListView: View {
    @Bindable var store: LoreStore
    @Binding var query: String
    @Binding var selected: IndexRow?
    let theme: HostTheme
    let onSelect: (IndexRow) -> Void
    let onNew: () -> Void
    /// Rename / move / trash, shared with `FolderTreeView`. Owns the
    /// confirmation dialog, the preview sheet and — new in Task 10 — the
    /// VISIBLE refusal when a delete is declined.
    let ops: SidebarOperations
    /// Lifted to `LoreRootView` so it can decide whether an active tag filter
    /// should force the flat list even while the sidebar is in tree mode.
    @Binding var activeTag: String?

    private var visible: [IndexRow] {
        // The default-hidden filter applies to BROWSING (`store.rows`) only,
        // never to `store.search(query)`. A search result is something the
        // owner explicitly asked for by typing a query — surfacing it is the
        // whole point of searching, and silently omitting `client_secret_…
        // .json` from a search for "client_secret" because it is an
        // attachment would be far more surprising than showing it. Browsing
        // is where a `.zip` reads as clutter; searching is where it reads as
        // "found it".
        var base = query.isEmpty
            ? DocumentVisibility.visibleRows(store.rows, showAllFiles: store.showAllFiles)
            : store.search(query)
        if let tag = activeTag { base = base.filter { $0.tags.contains(tag) } }
        return base
    }

    /// True when the reason the list looks empty is specifically that every
    /// row got hidden by the default filter — not "no notes exist" and not
    /// "the search/tag found nothing". Fix round 1, Minor 5: without this,
    /// a folder holding only a `.zip` and a `.json` read as "No matches"
    /// with the magnifying-glass icon, which implies a bad search rather
    /// than a setting the owner can flip. Scoped to the plain-browse case
    /// (`query` empty, no tag filter) because that is the only case where
    /// `DocumentVisibility` is even consulted — see `visible` above.
    private var allVisibleRowsAreHiddenByDefault: Bool {
        query.isEmpty && activeTag == nil && !store.showAllFiles
            && !store.rows.isEmpty
            && DocumentVisibility.visibleRows(store.rows, showAllFiles: false).isEmpty
    }

    var body: some View {
        // The search field and the "+" button used to live HERE, which meant
        // neither existed in tree mode — this view is not even mounted then.
        // They are now in `LoreRootView`'s sidebar header, above the mode
        // picker, so both are reachable in both modes. Tag chips stay here: they
        // are a flat-list filter by nature (a tag cuts across folders, so
        // filtering the tree by one leaves a scaffold of empty branches), and
        // `LoreRootView` already forces the flat list whenever a tag is active.
        VStack(spacing: AinkradSpacing.sm) {
            if !store.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AinkradSpacing.xs) {
                        ForEach(store.allTags, id: \.self) { tag in
                            AinkradSwatchChip(label: "#\(tag)",
                                              swatch: theme.tokens.accentSecondary,
                                              isOn: activeTag == tag) {
                                activeTag = (activeTag == tag) ? nil : tag
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if visible.isEmpty {
                AinkradEmptyState(
                    icon: store.rows.isEmpty ? "tray"
                        : allVisibleRowsAreHiddenByDefault ? "eye.slash" : "magnifyingglass",
                    title: store.rows.isEmpty ? "No notes yet"
                        : allVisibleRowsAreHiddenByDefault ? "Files are hidden" : "No matches",
                    message: store.rows.isEmpty
                        ? "Press ⌘N to capture your first note."
                        : allVisibleRowsAreHiddenByDefault
                            ? "Every file here is hidden by \"Show all files\" in Settings."
                            : "Try a different search or tag filter.",
                    actionTitle: store.rows.isEmpty ? "New note"
                        : allVisibleRowsAreHiddenByDefault ? "Show all files" : nil,
                    action: store.rows.isEmpty ? onNew
                        : allVisibleRowsAreHiddenByDefault ? { store.setShowAllFiles(true) } : nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visible, id: \.path) { row in
                            LoreSidebarRow.document(
                                row: row, depth: 0,
                                isSelected: selected?.path == row.path,
                                subtitle: row.tags.isEmpty
                                    ? nil : row.tags.map { "#\($0)" }.joined(separator: " "),
                                emptyTitleFallback: "Untitled",
                                onTap: { selected = row; onSelect(row) })
                                .ainkradContextMenu(loreRowMenuItems(row: row, ops: ops))
                        }
                    }
                }
            }
        }
        .padding(AinkradSpacing.md)
    }
}
