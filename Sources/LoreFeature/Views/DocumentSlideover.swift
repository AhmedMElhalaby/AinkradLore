import SwiftUI
import AinkradAppKit

/// Which side panel the slideover is showing.
enum DocumentPanel: String, Hashable, Sendable {
    case outline, backlinks

    var title: String {
        switch self {
        case .outline: return "Outline"
        case .backlinks: return "Linked mentions"
        }
    }

    var systemName: String {
        switch self {
        case .outline: return "list.bullet.indent"
        case .backlinks: return "link"
        }
    }
}

/// The slideover's selector, as a value.
///
/// Pure and view-free so the swap-versus-stack rule is asserted directly —
/// SwiftUI views are only smoke-testable in this project.
struct DocumentPanelState: Equatable, Sendable {
    private(set) var open: DocumentPanel?

    init() { open = nil }

    /// The buttons are a segmented selector: asking for the OTHER panel swaps
    /// the content, and asking for the open one closes it. Two independent
    /// toggles would let both panels stack over the editor, which is the
    /// stacked layout this task exists to remove.
    mutating func toggle(_ panel: DocumentPanel) {
        open = (open == panel) ? nil : panel
    }

    mutating func dismiss() { open = nil }
}

/// Right-edge overlay hosting one panel at a time.
///
/// It OVERLAYS the editor rather than narrowing it: the text column never
/// reflows, so the writing position is stable whether the panel is open or
/// shut. Fixed width by design — one less piece of persisted state for a panel
/// that is meant to be transient.
struct DocumentSlideover<Content: View>: View {
    let panel: DocumentPanel
    let theme: HostTheme
    let onClose: () -> Void
    @ViewBuilder let content: Content

    static var width: CGFloat { 280 }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack {
                Text(panel.title)
                    .foregroundStyle(theme.tokens.foreground)
                Spacer(minLength: AinkradSpacing.sm)
                AinkradIconButton(systemName: "xmark", tooltip: "Close",
                                  action: onClose)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(AinkradSpacing.md)
        .frame(width: Self.width)
        .background(theme.tokens.surfaceElevated)
        .shadow(color: .black.opacity(0.35), radius: 12, x: -4, y: 0)
        .transition(.move(edge: .trailing))
    }
}
