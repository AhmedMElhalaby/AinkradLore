import AppKit
import SwiftUI
import AinkradAppKit

/// The editor's style spans, and the text they describe.
///
/// The cache exists because `MarkdownDocumentModel.styleSpans` is a full parse
/// PLUS a link scan PLUS a `fullText.count`-sized offset table, and the editor's
/// `applyStyles()` runs on every keystroke and on every ancestor redraw — a
/// theme change, a banner appearing, a window resize. Before this cache a single
/// keystroke cost up to four parses. Identity of the text is the whole
/// invalidation rule: spans describe exactly one string, and `describes(_:)`
/// answers whether they still describe the one on screen.
struct MarkdownStyleCache {
    /// The string `spans` were derived from, or shifted to match.
    private(set) var text = ""
    private(set) var spans: [StyleSpan] = []
    /// Set from the model, so the renderer need not re-measure the string.
    private(set) var isOverHardCap = false
    private(set) var isOverViewportCap = false
    /// True when `spans` have been SHIFTED since the last parse — they are
    /// positioned correctly but may no longer be the right KINDS, because typing
    /// `*` can turn prose into emphasis. Only a parse settles that.
    private(set) var isStale = false

    func describes(_ candidate: String) -> Bool { text == candidate }

    /// Refreshes the spans from a real parse — EXCEPT above the hard cap, where
    /// the answer is `[]` and no parse is needed to say so.
    ///
    /// The guard has to be here, not in `MarkdownDocumentModel.init`: that
    /// initialiser also builds `codeRegions`, which the LINK GRAPH consumes, and
    /// making it skip work above a size would silently change which links
    /// resolve. The editor is the only consumer of style spans, so the editor is
    /// where "too big to style" is cheap to answer. Without this, the styling-OFF
    /// path was the most expensive path in the editor — a full parse per debounce
    /// to be handed an empty array.
    mutating func reparse(_ newText: String) {
        adopt(Self.derive(newText), for: newText)
    }

    /// Everything a parse produces, and nothing that is tied to a thread.
    ///
    /// `Sendable` so the parse can run OFF the main actor and the result be
    /// carried back — see `MarkdownEditor.Coordinator.parseNow`. The struct
    /// carries no reference to the editor, so there is nothing to race on; the
    /// string it describes travels alongside it and is checked on arrival.
    struct Derived: Sendable {
        let spans: [StyleSpan]
        let isOverHardCap: Bool
        let isOverViewportCap: Bool
    }

    /// The pure, actor-free half of `reparse`. Safe to call from any thread.
    static func derive(_ newText: String) -> Derived {
        guard newText.utf16.count <= MarkdownDocumentModel.stylingHardCap else {
            return Derived(spans: [], isOverHardCap: true, isOverViewportCap: true)
        }
        let model = MarkdownDocumentModel(fullText: newText)
        return Derived(spans: model.styleSpans,
                       isOverHardCap: model.isOverStylingHardCap,
                       isOverViewportCap: model.isOverStylingViewportCap)
    }

    /// Installs a derivation together with the string it describes.
    ///
    /// `text` is set from the caller's snapshot, never from the live view: the
    /// invariant `describes(text) ⇒ these spans index that exact string` is the
    /// only thing standing between a stale parse and styling the wrong
    /// characters, so the string and the spans are installed as one unit.
    mutating func adopt(_ derived: Derived, for newText: String) {
        text = newText
        spans = derived.spans
        isOverHardCap = derived.isOverHardCap
        isOverViewportCap = derived.isOverViewportCap
        isStale = false
    }

    /// Moves every cached span to where the edit put it, rather than dropping
    /// the styling until the next parse.
    ///
    /// Dropping would be correct and horrible: every keystroke would flash the
    /// document back to plain text for the length of the debounce. Shifting
    /// keeps the picture stable and is wrong only in the ways a parse 150 ms
    /// later fixes.
    ///
    /// One uniform rule, applied to both ends of every span: an offset at or
    /// before the edit stays put, an offset after it moves by the delta. That
    /// makes a span entirely after the edit slide, a span entirely before it
    /// hold still, and a span the caret is INSIDE grow — which is what typing
    /// inside `**bold**` should look like.
    ///
    /// - Parameter delta: replacement length minus `editedRange.length`, in
    ///   UTF-16 units.
    mutating func shift(editedRange: NSRange, delta: Int, newText: String) {
        let start = editedRange.location
        let limit = (newText as NSString).length
        text = newText
        isStale = true
        guard delta != 0 || editedRange.length != 0 else { return }

        spans = spans.compactMap { span in
            let lower = moved(span.range.lowerBound, start: start, delta: delta, limit: limit)
            let upper = moved(span.range.upperBound, start: start, delta: delta, limit: limit)
            // A deletion can collapse a span onto itself; an empty range styles
            // nothing, and an inverted one traps.
            guard upper > lower else { return nil }
            return StyleSpan(range: lower..<upper, kind: span.kind)
        }
    }

    private func moved(_ offset: Int, start: Int, delta: Int, limit: Int) -> Int {
        guard offset > start else { return min(offset, limit) }
        return min(max(start, offset + delta), limit)
    }
}

/// Turns style spans into text attributes.
///
/// Split out of `MarkdownEditor` so that file stays about the editor's AppKit
/// wiring — completion panel, Cmd-click, scroll observation — and this one about
/// appearance, which Task 9 will keep changing.
@MainActor
enum MarkdownStyleRenderer {
    static let baseSize: CGFloat = 14
    static var baseFont: NSFont { .monospacedSystemFont(ofSize: baseSize, weight: .regular) }

    /// How much text on either side of the visible range is styled in viewport
    /// mode. Big enough that a flick of the scroll wheel lands inside
    /// already-styled text; small enough to stay far cheaper than the document.
    static let viewportMargin = 20_000

    /// Applies `spans` to `storage`.
    ///
    /// ALWAYS clears first, over the whole string, even when `window` limits
    /// what is then styled. Clearing only the window would let an attribute
    /// survive the text that earned it — text that stops being bold but stays
    /// bold on screen — which is the exact failure this guards. `setAttributes`
    /// over the full range collapses the storage to one run, so the clear is
    /// cheap regardless of how much was styled before.
    static func apply(_ spans: [StyleSpan], to storage: NSTextStorage,
                      tokens: HostThemeTokens, limitedTo window: NSRange?) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor(tokens.foreground)
        ], range: full)

        for span in spans {
            let r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= full.length else { continue }
            if let window, NSIntersectionRange(r, window).length == 0 { continue }
            add(span.kind, in: r, to: storage, tokens: tokens)
        }
        storage.endEditing()
    }

    /// Syntax markers stay VISIBLE — this is Live Preview, not WYSIWYG — so
    /// every case styles the span's whole source range, markers included.
    private static func add(_ kind: StyleSpan.Kind, in r: NSRange,
                            to storage: NSTextStorage, tokens: HostThemeTokens) {
        switch kind {
        case .heading(let level):
            storage.addAttribute(.font, value: NSFont.boldSystemFont(
                ofSize: max(baseSize, 26 - CGFloat(level) * 2)), range: r)
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)

        case .strong:
            storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseSize), range: r)

        case .emphasis:
            storage.addAttribute(.font, value: NSFontManager.shared.convert(
                .systemFont(ofSize: baseSize), toHaveTrait: .italicFontMask), range: r)

        case .inlineCode, .codeBlock:
            storage.addAttribute(.font, value: baseFont, range: r)
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentSecondary), range: r)
            storage.addAttribute(.backgroundColor,
                                 value: NSColor(tokens.surfaceElevated).withAlphaComponent(0.45),
                                 range: r)

        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)
            storage.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: r)

        case .wikilink:
            // Colour, no underline. A wikilink already carries its own visible
            // `[[…]]` delimiters in Live Preview, so the underline was pure
            // noise on top of a marker the reader can already see.
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)

        case .blockQuote:
            storage.addAttribute(.foregroundColor,
                                 value: NSColor(tokens.foreground).withAlphaComponent(0.65),
                                 range: r)
            let style = NSMutableParagraphStyle()
            style.headIndent = 16
            storage.addAttribute(.paragraphStyle, value: style, range: r)

        case .checkbox:
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentTertiary), range: r)

        case .listItem:
            // Foreground unchanged by design: a list item is most of a note, and
            // tinting it would tint the note. Its children still style.
            break
        }
    }

    /// The visible character range plus a margin.
    ///
    /// Deliberately does NOT touch `tv.layoutManager`: reading that property on
    /// a TextKit 2 text view silently downgrades the whole view to TextKit 1.
    /// `characterIndexForInsertion(at:)` is the version-agnostic answer, and is
    /// already the API `LinkTextView` uses for Cmd-click.
    static func viewportWindow(of tv: NSTextView) -> NSRange {
        let length = (tv.string as NSString).length
        let visible = tv.visibleRect
        guard !visible.isEmpty else { return NSRange(location: 0, length: length) }
        let a = tv.characterIndexForInsertion(at: NSPoint(x: visible.minX, y: visible.minY))
        let b = tv.characterIndexForInsertion(at: NSPoint(x: visible.maxX, y: visible.maxY))
        let lower = max(0, min(a, b) - viewportMargin)
        let upper = min(length, max(a, b) + viewportMargin)
        return NSRange(location: lower, length: max(0, upper - lower))
    }
}
