import SwiftUI
import AinkradAppKit

/// Both kinds of sidebar row, built from the SAME component so their height,
/// padding, hover and selection cannot drift apart.
///
/// Folder rows used to be a bare `Button` wrapping an
/// `HStack(spacing: AinkradSpacing.xs)` with no padding at all, while document
/// rows were `AinkradListRow` (`.md` horizontal, `.sm` vertical, a `.md` gap
/// after the glyph). That is the entire cause of the mismatched spacing: two
/// row kinds with two sets of metrics, neither one wrong on its own.
///
/// The chevron is passed as `AinkradListRow`'s `leading`, which is what puts
/// it in the same column as a document's icon.
@MainActor
enum LoreSidebarRow {

    @ViewBuilder
    static func folder(name: String, depth: Int, isExpanded: Bool,
                       onToggle: @escaping () -> Void) -> some View {
        AinkradListRow(
            isSelected: false,
            onTap: onToggle,
            leading: {
                AinkradIconGlyph(systemName: isExpanded ? "chevron.down" : "chevron.right")
            },
            title: name,
            subtitle: nil,
            trailing: { EmptyView() })
            .padding(.leading, LoreSidebarMetrics.indent(depth: depth))
    }

    /// - Parameters:
    ///   - subtitle: Passed straight through to `AinkradListRow`. `nil` for
    ///     `FolderTreeView`'s tree rows; `NoteListView`'s tag-chip line for its
    ///     flat list.
    ///   - emptyTitleFallback: What to show when `row.title` is empty. `nil`
    ///     (the default) falls back to `row.path.lastPathComponent`, which is
    ///     what `FolderTreeView` wants and already had. `NoteListView` passes
    ///     `"Untitled"` to keep its own existing fallback — the two views
    ///     disagreed on this before the row types were unified, and unifying
    ///     the component is not an excuse to also unify a choice neither view
    ///     asked to change.
    /// - Parameter attributedSubtitle: A search excerpt with its matches
    ///   emphasised. Rendered BENEATH the row rather than inside it, because
    ///   `AinkradListRow.subtitle` is a plain `String` and the kit has no
    ///   attributed variant — and widening the kit would move the SDK
    ///   revision this plugin is pinned to, which is a far larger change than
    ///   a highlighted excerpt is worth. Takes precedence over `subtitle`:
    ///   two subtitles on one row would bury the more useful one.
    @ViewBuilder
    static func document(row: IndexRow, depth: Int, isSelected: Bool,
                         subtitle: String? = nil,
                         attributedSubtitle: AttributedString? = nil,
                         emptyTitleFallback: String? = nil,
                         onTap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AinkradListRow(
                isSelected: isSelected,
                onTap: onTap,
                leading: { AinkradIconGlyph(systemName: icon(for: row)) },
                title: row.title.isEmpty
                    ? (emptyTitleFallback ?? row.path.lastPathComponent) : row.title,
                subtitle: attributedSubtitle == nil ? subtitle : nil,
                trailing: { EmptyView() })
            if let attributedSubtitle {
                Text(attributedSubtitle)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Indented to the row's TITLE column, not its icon, so the
                    // excerpt reads as belonging to the title above it.
                    .padding(.leading, AinkradSpacing.lg + AinkradSpacing.md)
                    .padding(.trailing, AinkradSpacing.md)
                    .padding(.bottom, AinkradSpacing.xs)
            }
        }
        // The whole cell taps, excerpt included — an excerpt that is not part
        // of the click target is a strip of dead space in the middle of a list.
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .padding(.leading, LoreSidebarMetrics.indent(depth: depth))
    }

    static func icon(for row: IndexRow) -> String {
        row.type == AttachmentEngine.identifier ? "doc" : "doc.text"
    }
}
