import SwiftUI
import AinkradAppKit

struct NoteListView: View {
    @Bindable var store: LoreStore
    @Binding var query: String
    @Binding var selected: IndexRow?
    let theme: HostTheme
    let onSelect: (IndexRow) -> Void
    let onNew: () -> Void

    @State private var activeTag: String?

    private var visible: [IndexRow] {
        var base = query.isEmpty ? store.rows : store.search(query)
        if let tag = activeTag { base = base.filter { $0.tags.contains(tag) } }
        return base
    }

    var body: some View {
        VStack(spacing: AinkradSpacing.sm) {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradSearchField(text: $query, placeholder: "Search notes")
                AinkradIconButton(systemName: "plus", action: onNew)
                    .keyboardShortcut("n", modifiers: .command)
            }

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
                        }
                    }
                }
            }
        }
        .padding(AinkradSpacing.md)
    }
}
