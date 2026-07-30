import SwiftUI
import AinkradAppKit

struct NoteListView: View {
    @Bindable var store: LoreStore
    @Binding var query: String
    @Binding var selected: IndexRow?
    let theme: HostTheme
    let onSelect: (IndexRow) -> Void
    let onNew: () -> Void
    /// Delete affordance, inherited from the old `NoteEditorPane`: it lives on
    /// the row's context menu now that the editor pane is engine-owned.
    let onDelete: (IndexRow) -> Void
    /// Lifted to `LoreRootView` so it can decide whether an active tag filter
    /// should force the flat list even while the sidebar is in tree mode.
    @Binding var activeTag: String?

    /// The row a delete was requested for. Deleting a file is destructive and
    /// irreversible, so it keeps its confirmation.
    @State private var pendingDelete: IndexRow?

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
                            .contextMenu {
                                // Unclaimed rows list so the sidebar tells the
                                // truth about the vault — but Lore cannot open
                                // them, so M0 does not arm an irreversible
                                // delete against arbitrary binaries the user
                                // has no way to inspect here first. A later
                                // milestone can decide that deliberately.
                                if row.type != EngineRegistry.unclaimedType {
                                    Button("Delete", role: .destructive) { pendingDelete = row }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(AinkradSpacing.md)
        .ainkradConfirmDialog(
            isPresented: deleteBinding,
            title: "Delete document",
            message: "Delete “\(pendingDeleteName)”? This removes the file from disk.",
            confirmTitle: "Delete",
            isDestructive: true) {
                if let row = pendingDelete { onDelete(row) }
                pendingDelete = nil
            }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var pendingDeleteName: String {
        guard let row = pendingDelete else { return "" }
        return row.title.isEmpty ? row.path.lastPathComponent : row.title
    }
}
