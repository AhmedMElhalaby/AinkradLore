import AppKit

/// Which block a paragraph belongs to, for layout purposes only.
enum MarkdownBlock: Equatable {
    case body
    case heading(Int)
    case listItem(depth: Int)
    case blockQuote
    case codeBlock
}

/// Block layout as paragraph ATTRIBUTES.
///
/// Never as inserted whitespace: padding a list with spaces would change the
/// document text, and with it every offset the index, the link graph and the
/// MCP tools hold. Layout is a rendering concern and stays one.
enum MarkdownParagraphStyles {

    static func style(for block: MarkdownBlock, theme: MarkdownTheme) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.lineHeightMultiple = theme.lineHeightMultiple
        s.paragraphSpacing = theme.paragraphSpacing

        switch block {
        case .body:
            break

        case .heading(let level):
            s.paragraphSpacingBefore = theme.headingSpacingBefore(level)
            s.paragraphSpacing = theme.headingSpacingAfter(level)

        case .listItem(let depth):
            let base = theme.listIndentStep * CGFloat(depth + 1)
            s.firstLineHeadIndent = base
            // The hang: wrapped lines align under the item's TEXT, not under
            // its bullet. This single attribute is most of what makes a
            // multi-line bullet stop looking broken.
            s.headIndent = base + theme.listIndentStep
            // List items are lines of one list, not separate paragraphs.
            s.paragraphSpacing = theme.paragraphSpacing * 0.25

        case .blockQuote:
            // Room for the bar drawn in `MarkdownBlockBackgrounds`.
            s.firstLineHeadIndent = theme.listIndentStep
            s.headIndent = theme.listIndentStep

        case .codeBlock:
            s.firstLineHeadIndent = theme.listIndentStep * 0.5
            s.headIndent = theme.listIndentStep * 0.5
            // Code wraps badly; keep lines tight so a fence reads as a unit.
            s.lineHeightMultiple = 1.2
            s.paragraphSpacing = 0
        }
        return s
    }
}
