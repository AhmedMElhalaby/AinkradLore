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
        // `init(body:)`: the editor styles exactly the string it was given,
        // whole. For markdown that string is `note.body` (bound in
        // `MarkdownDocumentEditor`), already frontmatter-free; for plain text
        // there is no frontmatter to have. Either way a `Frontmatter.bodyOffset`
        // scan here can only mis-fire, and when it does the region above the
        // second `---` is simply left UNSTYLED — no bold, no headings, no
        // code-block background. Surviving spans still land correctly, because
        // `SourceOffsetMap` re-bases them; the defect is omission, not
        // misplacement.
        let model = MarkdownDocumentModel(body: newText)
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
