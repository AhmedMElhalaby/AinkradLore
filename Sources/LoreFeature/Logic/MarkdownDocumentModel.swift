import Foundation
import Markdown

/// The one place this application parses markdown.
///
/// Before M2a there were THREE scanners — a regex styler, a line-based outline
/// scan, and the link parser's span scanner — and they disagreed: the first two
/// were blind to code fences, so a `#` comment in a code block became a heading
/// in the index and `**bold**` inside a fence was styled. Every feature that
/// reads document structure now derives from this single parse.
public struct MarkdownDocumentModel: Sendable {
    public let offsetMap: SourceOffsetMap
    public let codeRangesUTF16: [NSRange]

    public init(fullText: String) {
        let bodyStart = Frontmatter.bodyOffset(in: fullText)
        let body = String(fullText.dropFirst(bodyStart))
        let bodyUTF16Offset = (String(fullText.prefix(bodyStart)) as NSString).length

        let map = SourceOffsetMap(body: body, bodyUTF16Offset: bodyUTF16Offset)
        let doc = Document(parsing: body)

        self.offsetMap = map
        self.codeRangesUTF16 = Self.codeRanges(in: doc, map: map)
    }

    public func isInsideCode(utf16Offset offset: Int) -> Bool {
        codeRangesUTF16.contains { NSLocationInRange(offset, $0) }
    }

    /// Every fenced block, indented block, HTML block, and inline code span.
    private static func codeRanges(in document: Document, map: SourceOffsetMap) -> [NSRange] {
        var collector = CodeRangeCollector(map: map)
        collector.visit(document)
        return collector.ranges
    }
}

/// Walks the AST collecting the source ranges of code.
///
/// A node whose `range` is nil contributes nothing rather than guessing — a
/// dropped range means a link inside that code is treated as a real link, which
/// is a visible wrong answer, whereas a GUESSED range could suppress a real
/// link silently. Neither is good; the visible one is preferable.
///
/// `SourceRange` is `Range<SourceLocation>` and swift-markdown has ALREADY
/// converted cmark's inclusive end column into an exclusive one (it adds 1 in
/// `CommonMarkConverter.range(_:)`), so `upperBound.column` is passed straight
/// through to `SourceOffsetMap.utf16Range`, which also treats `toColumn` as
/// exclusive. Adding a further +1 here would overrun every node by one unit.
struct CodeRangeCollector: MarkupWalker {
    let map: SourceOffsetMap
    var ranges: [NSRange] = []

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        append(codeBlock.range)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        append(inlineCode.range)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        append(html.range)
    }

    private mutating func append(_ sourceRange: SourceRange?) {
        guard let r = sourceRange,
              let ns = map.utf16Range(fromLine: r.lowerBound.line,
                                      fromColumn: r.lowerBound.column,
                                      toLine: r.upperBound.line,
                                      toColumn: r.upperBound.column) else { return }
        ranges.append(ns)
    }
}
