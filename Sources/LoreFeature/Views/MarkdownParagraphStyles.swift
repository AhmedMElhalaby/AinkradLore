import AppKit

/// Which block a paragraph belongs to, for layout purposes only.
enum MarkdownBlock: Equatable {
    case body
    case heading(Int)
    case listItem(depth: Int)
    case blockQuote
    case codeBlock
}

/// How deeply each `.listItem` span is nested.
///
/// `StyleSpan.Kind.listItem` carries no depth, and does not need to: nesting is
/// already in the ranges. `MarkdownASTCollector.visitListItem` appends the item
/// then `descendInto`s it, so a nested item is emitted AFTER its ancestors and
/// its range is strictly contained in theirs. Depth is therefore the number of
/// still-open ancestors — which a stack answers in one pass, without changing
/// the span kind and without a second walk of the document.
enum MarkdownListDepth {

    /// Depths aligned with `spans` by index. Entries for non-list spans are
    /// `0` and are never read; the array is index-aligned rather than a
    /// dictionary so the renderer's own loop can look a depth up by position.
    static func depths(of spans: [StyleSpan]) -> [Int] {
        var result = [Int](repeating: 0, count: spans.count)
        var open: [Range<Int>] = []
        for (index, span) in spans.enumerated() {
            guard case .listItem = span.kind else { continue }
            // Pop every ancestor this item is NOT inside. A sibling that starts
            // where the previous item ended closes it; a genuinely nested item
            // leaves it open.
            while let top = open.last,
                  !(span.range.lowerBound >= top.lowerBound
                    && span.range.upperBound <= top.upperBound) {
                open.removeLast()
            }
            result[index] = open.count
            open.append(span.range)
        }
        return result
    }
}

/// Block layout as paragraph ATTRIBUTES.
///
/// Never as inserted whitespace: padding a list with spaces would change the
/// document text, and with it every offset the index, the link graph and the
/// MCP tools hold. Layout is a rendering concern and stays one.
enum MarkdownParagraphStyles {

    /// A list item's style with its hang indent DERIVED from where the item's
    /// text actually starts.
    ///
    /// Additive to `style(for:theme:)`, which keeps its committed signature and
    /// its committed answer. That answer assumes the bullet is the only thing
    /// between the indent and the text — true at the top level, false the
    /// moment an item is nested, because the source indentation before a nested
    /// bullet is visible text that no marker collapses. The first line
    /// therefore begins at `firstLineHeadIndent + leadingIndent`, and a
    /// wrapped line hangs under the text only if `headIndent` says the same.
    ///
    /// - Parameter leadingIndent: the rendered width of the whitespace before
    ///   the item's bullet. Zero for a top-level item, where this degrades to
    ///   "wrapped lines align with the first line" — which, with the bullet
    ///   collapsed in the reading state, is exactly under the text.
    static func listItemStyle(depth: Int, leadingIndent: CGFloat,
                              theme: MarkdownTheme) -> NSParagraphStyle {
        let base = style(for: .listItem(depth: depth), theme: theme)
        guard let s = base.mutableCopy() as? NSMutableParagraphStyle else { return base }
        s.headIndent = s.firstLineHeadIndent + max(0, leadingIndent)
        return s
    }

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
