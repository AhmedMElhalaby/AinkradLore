import Foundation
import Markdown

/// One styled region of the editor's text.
public struct StyleSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(Int)
        case strong
        case emphasis
        case inlineCode
        case codeBlock(language: String?)
        case link
        case wikilink
        case listItem
        case blockQuote
        case checkbox(Bool)
    }
    /// UTF-16 offsets into the EDITOR's full string, frontmatter included.
    /// Not Character offsets — `LinkSpan.targetRange` uses those, and mixing
    /// the two misplaces every span in a document containing an emoji.
    public let range: Range<Int>
    public let kind: Kind

    public init(range: Range<Int>, kind: Kind) {
        self.range = range; self.kind = kind
    }
}

/// The prose half of the ONE markdown walk.
///
/// Style spans are collected by the SAME `MarkdownASTCollector` that collects
/// code regions, on the same pass over the same parse: `MarkdownDocumentModel`
/// deliberately does not retain the `Document` (`RawMarkup` is not `Sendable`),
/// so a second walk would mean a second parse, and two parses are exactly the
/// disagreement M2a exists to remove. The code-region visits live next to the
/// model because they feed its stored regions; the prose visits live here.
///
/// Every visit that has children must `descendInto`, or the walk stops at the
/// block level. Code blocks have no children, which is also why nothing inside
/// a fence can be styled as prose: the parser never produced a `Strong` there
/// to visit.
///
/// A node whose range fails to map is DROPPED, never applied to a guessed
/// range: a wrong range is visible and, were it ever to drive an edit,
/// destructive.
extension MarkdownASTCollector {

    mutating func visitHeading(_ heading: Heading) {
        append(heading.range, .heading(heading.level))
        descendInto(heading)
    }

    mutating func visitStrong(_ strong: Strong) {
        append(strong.range, .strong)
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        append(emphasis.range, .emphasis)
        descendInto(emphasis)
    }

    mutating func visitLink(_ link: Link) {
        append(link.range, .link)
        descendInto(link)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        append(blockQuote.range, .blockQuote)
        descendInto(blockQuote)
    }

    /// A task list item yields BOTH a `.listItem` for the item and a
    /// `.checkbox` for the marker alone. The checkbox range is found in the
    /// source rather than taken from the item's range, which spans the whole
    /// item: colouring an entire multi-line task as "checkbox" is not what any
    /// caller means by that kind.
    mutating func visitListItem(_ listItem: ListItem) {
        if let itemRange = resolve(listItem.range) {
            styleSpans.append(StyleSpan(range: swiftRange(itemRange), kind: .listItem))
            if let checkbox = listItem.checkbox,
               let markerRange = checkboxMarkerRange(in: itemRange) {
                styleSpans.append(StyleSpan(range: swiftRange(markerRange),
                                            kind: .checkbox(checkbox == .checked)))
            }
        }
        descendInto(listItem)
    }

    /// The `[ ]` / `[x]` marker on the item's FIRST line, in absolute UTF-16
    /// offsets. Searching only that line keeps a later `[` — a link, a
    /// footnote — from being mistaken for the marker.
    ///
    /// The EARLIEST of the three spellings wins, not the first one that
    /// happens to match: `- [x] see [ ] later` is a CHECKED item that mentions
    /// empty brackets, and scanning in marker order would put the span on the
    /// prose brackets while the kind said `.checkbox(true)`.
    private func checkboxMarkerRange(in itemRange: NSRange) -> NSRange? {
        var end = itemRange.location
        let limit = min(itemRange.location + itemRange.length, text.length)
        while end < limit, text.character(at: end) != 0x0A { end += 1 }
        guard end > itemRange.location else { return nil }
        let line = NSRange(location: itemRange.location,
                           length: end - itemRange.location)
        return ["[ ]", "[x]", "[X]"]
            .map { text.range(of: $0, options: [], range: line) }
            .filter { $0.location != NSNotFound }
            .min { $0.location < $1.location }
    }

    mutating func append(_ sourceRange: SourceRange?, _ kind: StyleSpan.Kind) {
        guard let ns = resolve(sourceRange) else { return }
        styleSpans.append(StyleSpan(range: swiftRange(ns), kind: kind))
    }

    func swiftRange(_ ns: NSRange) -> Range<Int> {
        ns.location..<(ns.location + ns.length)
    }
}

/// Wikilink spans, which the AST cannot supply.
///
/// `[[Design]]` is not CommonMark, so swift-markdown sees prose. They come from
/// `LinkParser` — the one scanner that already knows a wikilink inside a fence
/// is documentation about a link, not a link — filtered to `.wikilink`, with
/// its CHARACTER offsets converted to UTF-16 at the single boundary Task 4
/// established.
enum WikilinkSpanBuilder {
    /// - Parameter fullText: the EDITOR's string. `LinkParser` normalises CRLF
    ///   internally, which is offset-safe because `"\r\n"` is one Character —
    ///   so its character offsets still index `fullText`, and the table below
    ///   is built from `fullText` accordingly.
    /// - Parameter suppression: the caller's already-built suppression index,
    ///   when it describes `fullText` exactly; `nil` lets the parser compute its
    ///   own.
    ///
    /// The character→UTF-16 table comes BACK from the scan rather than being
    /// built here a second time — it is the same table over the same string, and
    /// building it twice was one `count`-sized allocation and one grapheme walk
    /// of pure duplication per parse.
    ///
    /// EXCEPT for CRLF documents, where the scan's table describes the
    /// NORMALISED string and `fullText`'s UTF-16 offsets are what the editor
    /// indexes. There the table is rebuilt from `fullText`, exactly as before.
    static func spans(in fullText: String, suppression: CodeRegionIndex?) -> [StyleSpan] {
        let scan = LinkParser.scan(fullText, suppression: suppression)
        let linkSpans = scan.spans.filter { $0.link.syntax == .wikilink }
        guard !linkSpans.isEmpty else { return [] }

        let utf16Offsets = scan.normalised
            ? CharacterOffsetMap.make(for: fullText) : scan.offsets

        return linkSpans.compactMap { span in
            guard span.targetRange.lowerBound >= 0,
                  span.targetRange.upperBound < utf16Offsets.count else { return nil }
            let lower = utf16Offsets[span.targetRange.lowerBound]
            let upper = utf16Offsets[span.targetRange.upperBound]
            return StyleSpan(range: lower..<upper, kind: .wikilink)
        }
    }
}
