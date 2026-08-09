import SwiftUI
import AinkradAppKit

/// One row of the import dry-run preview: a checkbox, the item's title, its
/// planned target path, and any `FidelityWarning`s — the user's only signal
/// that a conversion will lose something, so they are always shown, never
/// collapsed behind a disclosure.
struct ImportPreviewRow: View {
    let item: ImportItem
    /// Nil only when the item was excluded from the plan's input (i.e. it is
    /// currently deselected); in that case there is no target path to show.
    let planned: PlannedItem?
    let isAlreadyImported: Bool
    let isSelected: Bool
    let toggle: () -> Void

    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        AinkradListRow(
            isSelected: isSelected,
            onTap: isAlreadyImported ? nil : toggle,
            leading: { checkbox },
            title: item.title,
            subtitle: subtitle,
            trailing: { EmptyView() }
        )
        .opacity(isAlreadyImported ? 0.5 : 1)
    }

    @ViewBuilder private var checkbox: some View {
        if isAlreadyImported {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.foreground.opacity(0.4))
        } else {
            AinkradToggle(isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
        }
    }

    private var subtitle: String {
        var lines: [String] = []
        if isAlreadyImported {
            lines.append("Already imported")
        } else if let planned {
            switch planned.disposition {
            case .create:
                lines.append(planned.targetURL.lastPathComponent)
            case .renamedToAvoidCollision(let original):
                lines.append("\(planned.targetURL.lastPathComponent) (renamed from \(original) to avoid a collision)")
            case .alreadyImported:
                lines.append("Already imported")
            }
        }
        if !item.fidelity.isEmpty {
            lines.append(item.fidelity.map(\.detail).joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
