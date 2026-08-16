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
        /// An `![[target]]` embed's TARGET text — same convention as
        /// `.wikilink`'s content span: the brackets (and the leading `!`)
        /// sit OUTSIDE this range, as `.marker(of: .wikilink)` spans, so the
        /// SAME reveal machinery that shows/hides an ordinary wikilink's
        /// `[[`/`]]` on caret entry also shows/hides an embed's `![[`/`]]` —
        /// see Task 8 fix round 1, Important 6. `target` is the raw target
        /// (fragment included, alias excluded — see `DocumentLink.rawTarget`),
        /// for resolving what to render. `fullRange` is the WHOLE source
        /// form — `!`, both brackets and the target — because an IMAGE
        /// embed, unlike a chip, must collapse the target text too (there is
        /// no rasterized filename to show instead), and that collapse needs
        /// the outer bound the marker spans alone do not carry. See
        /// `EmbedRendering.applyEmbeds`.
        case embed(target: String, fullRange: Range<Int>)
        /// The syntax characters of `owner`, and NOTHING else. Emitted
        /// separately from the content span so Live Preview can collapse the
        /// markers without touching the text they delimit.
        case marker(of: MarkerOwner)

        /// Whether ONE opening marker and ONE closing marker delimit this kind,
        /// with the content between them.
        ///
        /// The reveal rule's one exception, and it lives on the kind rather than in
        /// `MarkdownReveal` so that adding a kind forces the question to be
        /// answered here — see `MarkdownReveal.revealedRange`. A span like this that
        /// crosses a line boundary must reveal WHOLE, or the caret sits inside
        /// syntax whose other half is hidden.
        ///
        /// `blockQuote`, `listItem` and `heading` answer `false`: each of their
        /// lines carries its own marker, so there is no pair to split, and
        /// revealing them together is the block-scoped behaviour being replaced.
        var isDelimitedByASinglePair: Bool {
            switch self {
            case .strong, .emphasis, .inlineCode, .codeBlock, .link, .wikilink, .embed:
                return true
            case .heading, .listItem, .blockQuote, .checkbox, .marker:
                return false
            }
        }
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

    /// Same walk as the style span, not a second one: `outline` and
    /// `astStyleSpans` are two views of the one `Heading` visit, and a node
    /// whose range fails to map is dropped from BOTH rather than guessed for
    /// either.
    mutating func visitHeading(_ heading: Heading) {
        if let ns = resolve(heading.range) {
            styleSpans.append(StyleSpan(range: swiftRange(ns), kind: .heading(heading.level)))
            outline.append(OutlineEntry(level: heading.level, text: heading.plainText,
                                        utf16Offset: ns.location))
            // A SETEXT heading has no `#` run, so `linePrefix` yields nothing
            // and no marker is emitted — the right answer, not a fallback.
            appendMarkers(MarkdownMarkers.linePrefix("#", in: ns, text: text), .heading)
        }
        descendInto(heading)
    }

    mutating func visitStrong(_ strong: Strong) {
        if let ns = resolve(strong.range) {
            styleSpans.append(StyleSpan(range: swiftRange(ns), kind: .strong))
            appendMarkers(MarkdownMarkers.paired(anyOf: ["**", "__"], in: ns, text: text),
                          .strong)
        }
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        if let ns = resolve(emphasis.range) {
            styleSpans.append(StyleSpan(range: swiftRange(ns), kind: .emphasis))
            appendMarkers(MarkdownMarkers.paired(anyOf: ["*", "_"], in: ns, text: text),
                          .emphasis)
        }
        descendInto(emphasis)
    }

    mutating func visitLink(_ link: Link) {
        if let ns = resolve(link.range) {
            styleSpans.append(StyleSpan(range: swiftRange(ns), kind: .link))
            appendMarkers(MarkdownMarkers.inlineLink(in: ns, text: text), .link)
        }
        descendInto(link)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if let ns = resolve(blockQuote.range) {
            styleSpans.append(StyleSpan(range: swiftRange(ns), kind: .blockQuote))
            appendMarkers(MarkdownMarkers.linePrefix(">", in: ns, text: text), .blockQuote)
        }
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
            appendMarkers(MarkdownMarkers.listBullet(in: itemRange, text: text), .listBullet)
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

    /// Marker spans are ADDITIVE — the content span keeps the range it always
    /// had, and these sit alongside it. An empty `ranges` (the "we are not sure
    /// what this looks like" answer from `MarkdownMarkers`) appends nothing.
    mutating func appendMarkers(_ ranges: [NSRange], _ owner: MarkerOwner) {
        for ns in ranges where ns.length > 0 {
            styleSpans.append(StyleSpan(range: swiftRange(ns), kind: .marker(of: owner)))
        }
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

        let ns = fullText as NSString
        return linkSpans.flatMap { span -> [StyleSpan] in
            guard span.targetRange.lowerBound >= 0,
                  span.targetRange.upperBound < utf16Offsets.count else { return [] }
            let lower = utf16Offsets[span.targetRange.lowerBound]
            let upper = utf16Offsets[span.targetRange.upperBound]
            // The CONTENT span covers the target only — the brackets sit
            // outside it, and for `[[Target|Display]]` the closer is past the
            // display text — so the markers are found in the source rather
            // than derived from this range's ends.
            let target = NSRange(location: lower, length: upper - lower)
            let brackets = MarkdownMarkers.wikilinkBrackets(around: target, text: ns)

            if span.link.isEmbed {
                // SAME shape as the ordinary wikilink case just below: a
                // content span (here `.embed`, over the target only) plus
                // marker spans for the delimiters — so `MarkdownReveal.
                // hiddenMarkers` collapses and reveals an embed's `![[`/`]]`
                // exactly the way it already does an ordinary wikilink's
                // `[[`/`]]`. Fixed in Task 8 fix round 1 (Important 6): the
                // first version made the WHOLE `![[target]]` one span with no
                // separate markers, which meant an embed's raw source could
                // never be revealed for editing — no way to fix a typo'd
                // target in place.
                //
                // The leading `!` joins the OPEN bracket's marker span rather
                // than getting one of its own: it has no meaning on its own
                // and a caret landing exactly between `!` and `[[` should not
                // find one revealed and the other hidden.
                guard brackets.count == 2 else {
                    // Malformed (no `[[`/`]]` found around the target) — fall
                    // back to the target alone with no markers, rather than
                    // dropping the span, so a broken document still gets SOME
                    // representation.
                    return [StyleSpan(range: lower..<upper,
                                      kind: .embed(target: span.link.rawTarget, fullRange: lower..<upper))]
                }
                let open = brackets[0]
                var bangStart = open.location
                if bangStart > 0, ns.character(at: bangStart - 1) == 0x21 /* "!" */ { bangStart -= 1 }
                let close = brackets[1]
                let fullEnd = close.location + close.length
                let openWithBang = NSRange(location: bangStart,
                                           length: (open.location + open.length) - bangStart)
                return [StyleSpan(range: lower..<upper,
                                  kind: .embed(target: span.link.rawTarget,
                                              fullRange: bangStart..<fullEnd)),
                        StyleSpan(range: openWithBang.location..<(openWithBang.location + openWithBang.length),
                                  kind: .marker(of: .wikilink)),
                        StyleSpan(range: close.location..<(close.location + close.length),
                                  kind: .marker(of: .wikilink))]
            }

            return [StyleSpan(range: lower..<upper, kind: .wikilink)]
                + brackets.map {
                    StyleSpan(range: $0.location..<($0.location + $0.length),
                              kind: .marker(of: .wikilink))
                }
        }
    }
}
