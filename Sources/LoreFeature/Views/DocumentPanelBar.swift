import SwiftUI
import AinkradAppKit

/// The slim bottom bar that opens the slideover.
///
/// Counts ride on the buttons as badges: "Linked mentions (0)" stays
/// answerable without opening anything, which is most of what the
/// always-visible panel was actually providing.
struct DocumentPanelBar: View {
    let counts: [DocumentPanel: Int]
    let open: DocumentPanel?
    let theme: HostTheme
    let onToggle: (DocumentPanel) -> Void

    var body: some View {
        HStack(spacing: AinkradSpacing.sm) {
            ForEach([DocumentPanel.outline, .backlinks], id: \.self) { panel in
                button(panel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AinkradSpacing.md)
        .padding(.vertical, AinkradSpacing.xs)
        .background(theme.tokens.background)
    }

    @ViewBuilder
    private func button(_ panel: DocumentPanel) -> some View {
        let count = counts[panel] ?? 0
        Button {
            onToggle(panel)
        } label: {
            HStack(spacing: AinkradSpacing.xs) {
                AinkradIconGlyph(systemName: panel.systemName, size: 11)
                Text("\(count)")
                    .foregroundStyle(theme.tokens.foreground.opacity(0.7))
            }
            .padding(.horizontal, AinkradSpacing.sm)
            .padding(.vertical, AinkradSpacing.xs)
            .background(ChamferShape(cut: 4).fill(open == panel
                        ? theme.tokens.accentSecondary.opacity(0.2) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(panel.title)
        .accessibilityLabel("\(panel.title), \(count) items")
    }
}
