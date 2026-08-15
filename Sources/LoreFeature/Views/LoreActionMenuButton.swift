import SwiftUI
import AinkradAppKit

/// A button that opens a menu on a LEFT click.
///
/// ## The bug this exists to fix
///
/// The document header's ⋯ button was an `AinkradIconButton` with an empty
/// action and `.ainkradContextMenu(…)` attached. That modifier presents on
/// RIGHT-click — it is the kit's context-menu API and says so — so left-clicking
/// the button did precisely nothing. A control whose entire purpose is to be
/// clicked, that ignores clicks, and whose only working gesture is the one
/// nobody tries on a toolbar button.
///
/// It also never showed up in a test: the smoke tests build the header, and a
/// view that builds fine can still be inert.
///
/// ## Why it renders the same `AinkradMenuItem` list
///
/// The items come from `loreRowMenuItems`, the same builder the sidebar's
/// right-click menu uses. A click menu that assembled its own rows would be a
/// second definition of the document's destructive affordances — the exact
/// duplication that builder exists to prevent.
struct LoreActionMenuButton: View {
    let systemName: String
    let tooltip: String
    let items: [AinkradMenuItem]
    let theme: HostTheme

    @State private var isPresented = false
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        AinkradIconButton(systemName: systemName, tooltip: tooltip) {
            isPresented.toggle()
        }
        .accessibilityLabel(tooltip)
        .ainkradPopover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in row(item) }
            }
            .frame(minWidth: 200, alignment: .leading)
        }
    }

    private func row(_ item: AinkradMenuItem) -> some View {
        Button {
            // Dismissed BEFORE the action runs: several of these open a sheet
            // of their own, and a popover left standing over it swallows the
            // sheet's first click.
            isPresented = false
            item.action()
        } label: {
            HStack(spacing: AinkradSpacing.sm) {
                if let systemName = item.systemName {
                    AinkradIconGlyph(systemName: systemName, size: 11)
                }
                Text(item.title)
                    .font(AinkradFontResolver.font(.body, typography: typo))
                Spacer(minLength: AinkradSpacing.md)
                if let shortcut = item.shortcut {
                    AinkradKbd(shortcut)
                }
            }
            .foregroundStyle(item.isDestructive
                             ? theme.tokens.accentPrimary
                             : theme.tokens.foreground)
            .padding(.horizontal, AinkradSpacing.sm)
            .padding(.vertical, AinkradSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
