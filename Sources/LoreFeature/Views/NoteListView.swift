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
        var base = query.isEmpty ? store.rows : store.search(query)
        if let tag = activeTag { base = base.filter { $0.tags.contains(tag) } }
        return base
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
                    icon: store.rows.isEmpty ? "tray" : "magnifyingglass",
                    title: store.rows.isEmpty ? "No notes yet" : "No matches",
                    message: store.rows.isEmpty
                        ? "Press ⌘N to capture your first note."
                        : "Try a different search or tag filter.",
                    actionTitle: store.rows.isEmpty ? "New note" : nil,
                    action: store.rows.isEmpty ? onNew : nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visible, id: \.path) { row in
                            AinkradListRow(
                                isSelected: selected?.path == row.path,
                                onTap: { selected = row; onSelect(row) },
                                leading: { AinkradIconGlyph(systemName: "doc.text") },
                                title: row.title.isEmpty ? "Untitled" : row.title,
                                subtitle: row.tags.isEmpty
                                    ? nil : row.tags.map { "#\($0)" }.joined(separator: " "),
                                trailing: { EmptyView() })
                            .contextMenu { LoreRowMenu(row: row, ops: ops) }
                        }
                    }
                }
            }
        }
        .padding(AinkradSpacing.md)
    }
}
