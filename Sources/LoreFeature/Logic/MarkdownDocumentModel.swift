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
    /// one — see `isFenced(at:code:)`.
    let text: NSString
    var regions: [CodeRegion] = []

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let ns = resolve(codeBlock.range) else { return }
        regions.append(CodeRegion(range: ns,
                                  kind: isFenced(at: ns, code: codeBlock.code)
                                      ? .fencedCodeBlock : .indentedCodeBlock))
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let ns = resolve(inlineCode.range) else { return }
        regions.append(CodeRegion(range: ns, kind: .inlineCode))
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        guard let ns = resolve(html.range) else { return }
        regions.append(CodeRegion(range: ns, kind: .htmlBlock))
    }

    /// Fenced or indented? swift-markdown models both as `CodeBlock`, and
    /// `language` / `fenceInfo` is nil for a bare ``` opener as well as for
    /// indented code, so neither can discriminate.
    ///
    /// `CodeBlock.range` starts at the block's CONTENT, never at column 1 — a
    /// 4-space indented block reports its start already PAST the indent. So
    /// leading whitespace is invisible here, and column arithmetic cannot help
    /// either: a fence nested in a list and an indented code block both report
    /// column 5. The discriminator has to be the text itself, in two parts.
    ///
    /// 1. The range must START with a run of 3+ backticks or tildes. Necessary,
    ///    not sufficient — an INDENTED block whose first content line happens to
    ///    be ```` ``` ```` also satisfies it, and reading that as a fence made
    ///    the block suppress links, which the owner's ruling forbids.
    /// 2. So: reject when the block's own CONTENT contains a line that would
    ///    have CLOSED that fence — a bare run of the same character, at least as
    ///    long. CommonMark guarantees a real fenced block can never contain such
    ///    a line, because it would have terminated the block. Only an indented
    ///    block can. `[[X]]` inside `"    ```\n    [[X]]\n    ```"` therefore
    ///    stays a link, while ```` ```` ````-fenced content containing ```` ``` ````
    ///    (a shorter run) is still correctly fenced.
    ///
    /// Every content line is checked, not just the first: an indented block may
    /// open with an info-string line (`    ```swift`), which is not itself a
    /// closer, and only reveal the bare closer further down.
    ///
    /// "Bare" matters: ` ```text ` does not close a fence, so a fenced block MAY
    /// contain it, and it must not be mistaken for indented code.
    ///
    /// KNOWN LIMIT: an indented block that opens with an info-string fence line
    /// and never contains a bare closing run (`"    ```swift\n    [[X]]"`, no
    /// terminator) still reads as fenced and suppresses. It needs 4-space
    /// indentation, a fence-shaped first line WITH an info string, and no bare
    /// fence line anywhere in the block.
    private func isFenced(at range: NSRange, code: String) -> Bool {
        guard let marker = leadingFenceRun(in: sourceLine(at: range)) else {
            return false
        }
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            if let closer = leadingFenceRun(in: String(line)),
               closer.character == marker.character,
               closer.length >= marker.length,
               closer.isBare {
                return false
            }
        }
        return true
    }

    /// The source text from `range`'s start to the end of that line.
    private func sourceLine(at range: NSRange) -> String {
        var end = range.location
        while end < text.length, text.character(at: end) != 0x0A { end += 1 }
        guard end > range.location else { return "" }
        return text.substring(with: NSRange(location: range.location,
                                            length: end - range.location))
    }

    private func leadingFenceRun(in line: String)
        -> (character: Character, length: Int, isBare: Bool)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let rest = line[run.endIndex...]
        return (first, run.count, rest.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" })
    }

    private func resolve(_ sourceRange: SourceRange?) -> NSRange? {
        guard let r = sourceRange else { return nil }
        return map.utf16Range(fromLine: r.lowerBound.line,
                              fromColumn: r.lowerBound.column,
                              toLine: r.upperBound.line,
                              toColumn: r.upperBound.column)
    }
}
