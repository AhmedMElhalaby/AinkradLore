import SwiftUI
import AinkradAppKit

/// The open markdown document's headings, indented by level, in `DocumentPane`
/// alongside `BacklinksPanel`.
///
/// `outline` is handed in rather than fetched here: it comes straight from
/// `MarkdownEngine.indexPayload`, which `DocumentPane` already has to reach
/// past (only markdown contributes an outline), and duplicating that access
/// here would be a second, divergent way to ask the same question.
struct OutlineSection: View {
    @Bindable var store: LoreStore
    let outline: [OutlineEntry]
    let theme: HostTheme
    /// Called with a heading's body-relative UTF-16 offset. `DocumentPane`
    /// forwards this to whatever `registerScrollHandler` handed it — see
    /// `EditorContext.registerScrollHandler`.
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            Button {
                store.setOutlinePanelExpanded(!store.outlinePanelExpanded)
            } label: {
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradIconGlyph(systemName: store.outlinePanelExpanded
                        ? "chevron.down" : "chevron.right")
                    Text("Outline (\(outline.count))")
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if store.outlinePanelExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                        ForEach(Array(outline.enumerated()), id: \.offset) { _, entry in
                            Button { onSelect(entry.utf16Offset) } label: {
                                Text(entry.text)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    // 12pt per level below the first: a visible
                                    // hierarchy without needing a disclosure
                                    // triangle per heading.
                                    .padding(.leading, CGFloat(max(0, entry.level - 1)) * 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(AinkradSpacing.sm)
        .background(theme.tokens.background)
    }
}
