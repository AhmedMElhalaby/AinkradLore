import Foundation
import Markdown

/// The one place this application parses markdown.
///
/// Before M2a there were THREE scanners — a regex styler, a line-based outline
/// scan, and the link parser's span scanner — and they disagreed: the first two
/// were blind to code fences, so a `#` comment in a code block became a heading
/// in the index and `**bold**` inside a fence was styled. Every feature that
/// reads document structure now derives from this single parse.
/// What kind of raw-text region a `CodeRegion` came from.
///
/// Kinds exist because "is this code?" has two different right answers depending
/// on who is asking. A styler wants every raw-text region. The LINK GRAPH wants
/// only the regions the old hand-written scanner recognised — fenced and inline
/// code — because widening it silently deletes links from real notes: a
/// CommonMark type-6 HTML block runs to the next BLANK line, so `[[R]]` in an
/// ordinary prose line after a `</div>` would stop being a link at all.
public enum CodeRegionKind: Sendable, Equatable, Hashable {
    case fencedCodeBlock
    case indentedCodeBlock
    case inlineCode
    case htmlBlock
}

public struct CodeRegion: Sendable, Equatable {
    public let range: NSRange
    public let kind: CodeRegionKind
}

public struct MarkdownDocumentModel: Sendable {
    public let offsetMap: SourceOffsetMap

    /// Every raw-text region, tagged. Ordered as the walk found them.
    public let codeRegions: [CodeRegion]

    /// Every code region's range, kind discarded. Unchanged in meaning from
    /// before kinds existed: fenced, indented, HTML block, and inline code.
    public var codeRangesUTF16: [NSRange] { codeRegions.map(\.range) }

    /// The kinds the LINK GRAPH suppresses on. Deliberately NOT every kind —
    /// see `CodeRegionKind`.
    public static let linkSuppressingKinds: Set<CodeRegionKind> = [
        .fencedCodeBlock, .inlineCode,
    ]

    public init(fullText: String) {
        let bodyStart = Frontmatter.bodyOffset(in: fullText)
        let body = String(fullText.dropFirst(bodyStart))
        let bodyUTF16Offset = (String(fullText.prefix(bodyStart)) as NSString).length

        let map = SourceOffsetMap(body: body, bodyUTF16Offset: bodyUTF16Offset)
        let doc = Document(parsing: body)

        self.offsetMap = map
        var collector = CodeRangeCollector(map: map, text: fullText as NSString)
        collector.visit(doc)
        self.codeRegions = collector.regions
    }

    /// True if `offset` is inside ANY code region. Semantics unchanged: callers
    /// that genuinely want every raw-text region keep using this.
    public func isInsideCode(utf16Offset offset: Int) -> Bool {
        codeRegions.contains { NSLocationInRange(offset, $0.range) }
    }

    /// True if `offset` is inside a code region of one of `kinds`.
    public func isInsideCode(utf16Offset offset: Int, kinds: Set<CodeRegionKind>) -> Bool {
        codeRegions.contains {
            kinds.contains($0.kind) && NSLocationInRange(offset, $0.range)
        }
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
    /// The FULL text, used only to tell a fenced code block from an indented
    /// one. swift-markdown models both as `CodeBlock`, and `fenceInfo` is nil
    /// for a bare ``` opener as well as for indented code, so it cannot
    /// discriminate. The source text can: a fenced block's range starts at its
    /// own fence marker.
    let text: NSString
    var regions: [CodeRegion] = []

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let ns = resolve(codeBlock.range) else { return }
        regions.append(CodeRegion(range: ns,
                                  kind: isFenced(at: ns) ? .fencedCodeBlock
                                                         : .indentedCodeBlock))
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let ns = resolve(inlineCode.range) else { return }
        regions.append(CodeRegion(range: ns, kind: .inlineCode))
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        guard let ns = resolve(html.range) else { return }
        regions.append(CodeRegion(range: ns, kind: .htmlBlock))
    }

    private func isFenced(at range: NSRange) -> Bool {
        // Up to 3 leading spaces are permitted before a fence, so 6 units is
        // enough to see a full 3-character marker in the worst case.
        let probeLength = min(6, text.length - range.location)
        guard probeLength > 0 else { return false }
        let head = text.substring(with: NSRange(location: range.location,
                                                length: probeLength))
        let marker = head.drop { $0 == " " }
        return marker.hasPrefix("```") || marker.hasPrefix("~~~")
    }

    private func resolve(_ sourceRange: SourceRange?) -> NSRange? {
        guard let r = sourceRange else { return nil }
        return map.utf16Range(fromLine: r.lowerBound.line,
                              fromColumn: r.lowerBound.column,
                              toLine: r.upperBound.line,
                              toColumn: r.upperBound.column)
    }
}
