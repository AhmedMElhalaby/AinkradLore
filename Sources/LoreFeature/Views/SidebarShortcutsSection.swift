import SwiftUI
import AinkradAppKit

/// Pinned and recent documents, above the browse list.
///
/// Deliberately ABOVE the mode picker and shared by both sidebar modes: these
/// are not a third way of browsing the vault, they are a shortcut past
/// browsing entirely, and they answer the same question whether the list below
/// is a tree or a flat list.
///
/// Hidden entirely when both lists are empty — which is every first-run vault.
/// A pair of empty sections labelled "Pinned" and "Recent" above an empty note
/// list is three ways of saying "nothing here" stacked on top of each other.
struct SidebarShortcutsSection: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @Binding var selected: IndexRow?
    let onSelect: (IndexRow) -> Void
    let ops: SidebarOperations

    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        let pinned = store.pinnedRows
        // Recents are capped in the VIEW as well as the store: the store keeps
        // ten so that a few going stale still leaves a useful list, but showing
        // ten recents plus pins pushes the actual vault off the top of the
        // sidebar, which is the opposite of a shortcut.
        let recents = Array(store.recentRows.prefix(5))
        if !pinned.isEmpty || !recents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !pinned.isEmpty {
                    header("Pinned")
                    ForEach(pinned, id: \.path) { row in shortcutRow(row) }
                }
                if !recents.isEmpty {
                    header("Recent")
                    ForEach(recents, id: \.path) { row in shortcutRow(row) }
                }
                Divider().opacity(0.4).padding(.vertical, AinkradSpacing.xs)
            }
            .padding(.horizontal, AinkradSpacing.md)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AinkradFontResolver.font(.caption, typography: typo))
            .foregroundStyle(theme.tokens.foreground.opacity(LoreMetrics.tertiaryText))
            .padding(.top, AinkradSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    /// A shortcut row is the SAME row component the browse lists use, so a
    /// document does not change shape depending on which part of the sidebar
    /// it appears in — and so selection, hover and the context menu behave
    /// identically in both.
    private func shortcutRow(_ row: IndexRow) -> some View {
        LoreSidebarRow.document(
            row: row, depth: 0,
            isSelected: selected?.path == row.path,
            emptyTitleFallback: "Untitled",
            onTap: { selected = row; onSelect(row) })
            .loreDraggableDocument(row)
            .ainkradContextMenu(loreRowMenuItems(row: row, ops: ops, store: store))
    }
}
