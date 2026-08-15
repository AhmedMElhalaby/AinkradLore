import SwiftUI
import AinkradAppKit

/// What else in the vault points at this document, shown BELOW its body.
///
/// ## Why below, and not in a panel
///
/// Linked mentions and the outline were peers in one slideover, and they are
/// not peers at all. The outline answers *where am I* — asked constantly,
/// while writing, for half a second at a time (it is now the spine rail).
/// This answers *what else refers to this* — asked rarely, between writing
/// sessions, and then you want to read it properly. A 160pt-capped list in a
/// 280pt drawer served neither.
///
/// Below the last line is where it costs nothing: you never scroll past the
/// end of a document mid-sentence, so while you are writing this is simply not
/// on screen. When you have finished reading, it is exactly where you already
/// are. It scrolls WITH the text (see `MarkdownEditorContainerView`) rather
/// than floating over it, so it reads as part of the document's tail rather
/// than as chrome stuck to the pane.
///
/// It is free to be as tall as it needs. The old panel's `maxHeight: 160` cap
/// existed because it shared a drawer; nothing constrains it here.
struct DocumentMentionsFooter: View {
    let backlinks: [LoreStore.Backlink]
    let unresolved: [UnresolvedLink]
    let theme: HostTheme
    let onOpen: (URL) -> Void
    let onCreate: (UnresolvedLink) -> Void

    @Environment(\.ainkradTypography) private var typo
    @State private var expanded = false

    /// Collapsed by default, and summarised in one line.
    ///
    /// The summary is the point: "7 linked mentions · 2 unresolved" answers the
    /// question most of the time without expanding anything, which is why the
    /// old panel's count badge was most of what it actually provided.
    private var summary: String {
        var parts = [backlinks.count == 1 ? "1 linked mention"
                                          : "\(backlinks.count) linked mentions"]
        if !unresolved.isEmpty { parts.append("\(unresolved.count) unresolved") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        // Nothing points here and nothing is broken: draw NOTHING. An empty
        // "0 linked mentions" band at the foot of every new note is a permanent
        // reminder of an absence, and it would be the first thing a reader sees
        // under a document they just started.
        if !backlinks.isEmpty || !unresolved.isEmpty {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                Divider().opacity(0.5)
                disclosure
                if expanded { details }
            }
            .padding(.horizontal, LoreMetrics.gutter)
            .padding(.bottom, AinkradSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.ainkradTheme, theme.tokens)
        }
    }

    private var disclosure: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: AinkradSpacing.xs) {
                AinkradIconGlyph(systemName: expanded ? "chevron.down" : "chevron.right",
                                 size: 10)
                Text(summary)
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide \(summary)" : "Show \(summary)")
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            ForEach(backlinks) { link in
                Button { onOpen(link.row.path) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.row.title)
                            .font(AinkradFontResolver.font(.headline, typography: typo))
                            .lineLimit(1)
                        if !link.context.isEmpty {
                            // The LINE the link sits on. A bare list of
                            // filenames is meaningfully less useful than seeing
                            // WHY something links here — the rule the old panel
                            // established and this keeps.
                            Text(link.context)
                                .font(AinkradFontResolver.font(.caption, typography: typo))
                                .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !unresolved.isEmpty {
                AinkradSectionHeader(title: "Unresolved links")
                ForEach(unresolved) { link in
                    HStack(spacing: AinkradSpacing.sm) {
                        Text(link.rawTarget).lineLimit(1)
                        Spacer(minLength: 0)
                        AinkradButton(title: "Create note", style: .ghost) {
                            onCreate(link)
                        }
                    }
                }
            }
        }
    }
}
