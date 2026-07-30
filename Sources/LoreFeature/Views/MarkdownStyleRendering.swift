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

/// The scroll-to-offset entry point `OutlineSection` drives, kept here rather
/// than in `MarkdownEditor.swift` to leave that file's AppKit wiring alone —
/// see that file's line-count note.
extension MarkdownEditor.Coordinator {
    /// Moves the caret to `offset` (UTF-16, into the editor's text) and
    /// scrolls it on screen. Clamped rather than guarded: an outline entry
    /// computed against a slightly stale model (edit landed between parse and
    /// click) should still land somewhere sane, not be silently dropped.
    @MainActor func scrollToOffset(_ offset: Int) {
        guard let tv = textView else { return }
        let length = (tv.string as NSString).length
        let clamped = max(0, min(offset, length))
        let range = NSRange(location: clamped, length: 0)
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
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

    // MARK: - Font composition

    /// Rewrites the `.font` attribute over `r` as a FUNCTION of the font
    /// already there, run by run.
    ///
    /// Spans arrive parent-first (`MarkdownSpanBuilder` appends a node then
    /// `descendInto`s it) and `apply` walks them in array order, so a child's
    /// font landed on top of its parent's and REPLACED it: `# A **B** C` drew
    /// `B` at the base 14 pt inside a 24 pt heading, `**bold _and_ italic**`
    /// drew the inner run italic-and-not-bold, and inline code in a heading
    /// dropped to base size. Composition has to accumulate, so each kind now
    /// states a DELTA — "add bold", "keep the size, switch to monospace" — and
    /// reads the rest from what the ancestors already put there.
    ///
    /// The runs are collected BEFORE any are written: mutating attributes from
    /// inside `enumerateAttribute`'s block mutates the thing being enumerated.
    private static func composeFont(in r: NSRange, storage: NSTextStorage,
                                    _ transform: (NSFont) -> NSFont) {
        var runs: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: r) { value, sub, _ in
            runs.append((sub, (value as? NSFont) ?? baseFont))
        }
        for (sub, font) in runs {
            storage.addAttribute(.font, value: transform(font), range: sub)
        }
    }

    /// The traits a child span must carry over from its ancestors. Bold and
    /// italic only — those are the two the markdown kinds compose. Anything
    /// else (a condensed or expanded face) is not something this renderer sets,
    /// so re-applying it would be inventing state.
    private static func inheritedTraits(of font: NSFont) -> NSFontTraitMask {
        let traits = NSFontManager.shared.traits(of: font)
        var inherited: NSFontTraitMask = []
        if traits.contains(.boldFontMask) { inherited.insert(.boldFontMask) }
        if traits.contains(.italicFontMask) { inherited.insert(.italicFontMask) }
        return inherited
    }

    /// `convert` returns the font UNCHANGED when the family has no such face,
    /// so an unavailable monospaced-italic degrades to upright rather than
    /// falling back to a different family and changing the metrics mid-line.
    private static func applying(_ traits: NSFontTraitMask, to font: NSFont) -> NSFont {
        var result = font
        if traits.contains(.boldFontMask) {
            result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italicFontMask) {
            result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }

    /// Syntax markers stay VISIBLE — this is Live Preview, not WYSIWYG — so
    /// every case styles the span's whole source range, markers included.
    private static func add(_ kind: StyleSpan.Kind, in r: NSRange,
                            to storage: NSTextStorage, tokens: HostThemeTokens) {
        switch kind {
        case .heading(let level):
            let size = max(baseSize, 26 - CGFloat(level) * 2)
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current).union(.boldFontMask),
                              to: .systemFont(ofSize: size))
            }
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)

        case .strong:
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current).union(.boldFontMask),
                              to: .systemFont(ofSize: current.pointSize))
            }

        case .emphasis:
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current).union(.italicFontMask),
                              to: .systemFont(ofSize: current.pointSize))
            }

        case .inlineCode:
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current),
                              to: .monospacedSystemFont(ofSize: current.pointSize,
                                                        weight: .regular))
            }
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentSecondary), range: r)
            storage.addAttribute(.backgroundColor,
                                 value: NSColor(tokens.surfaceElevated).withAlphaComponent(0.45),
                                 range: r)

        case .codeBlock(let language):
            // Task 9's scope: monospace, a background, a language label. NO
            // per-token colouring — that would reintroduce exactly the
            // hand-rolled scanning this milestone removed. The uniform
            // `accentSecondary` tint over the WHOLE block (kept from Task 6)
            // is not that: it is one colour for one span, same as
            // `.inlineCode`, and it is what makes a fence read as code at a
            // glance rather than as indented prose. Removing it would leave
            // code visually identical to a blockquote save for the
            // background, which is a worse outcome than the tint's own
            // "changes every existing note" cost — so it stays.
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current),
                              to: .monospacedSystemFont(ofSize: current.pointSize,
                                                        weight: .regular))
            }
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentSecondary), range: r)
            storage.addAttribute(.backgroundColor,
                                 value: NSColor(tokens.surfaceElevated).withAlphaComponent(0.45),
                                 range: r)
            if let language, !language.isEmpty {
                styleLanguageLabel(language, in: r, storage: storage, tokens: tokens)
            }

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

        case .marker:
            // Deliberately inert HERE. Marker spans exist so a later task can
            // dim or collapse syntax characters; giving them an appearance now
            // would change every note's look ahead of that decision, and the
            // rendering above already styles the whole source range including
            // its markers.
            break
        }
    }

    /// Styles the info string (`swift` in an opening ```` ```swift ```` line)
    /// as a trailing label on that line, distinct from the block's body.
    ///
    /// `CodeBlock.range` covers the opening fence line itself (verified in
    /// `test_codeBlockSpanRangeIncludesTheOpeningFence`), so the language text
    /// is real characters already inside `r` — no attachment, no overlay
    /// drawing, no second pass over the layout manager. The label is found by
    /// locating the block's first line and searching it for `language`, which
    /// is safe because CommonMark's info string is exactly that word (an
    /// identifier, no spaces) immediately after the fence run.
    private static func styleLanguageLabel(_ language: String, in r: NSRange,
                                           storage: NSTextStorage, tokens: HostThemeTokens) {
        let full = storage.string as NSString
        let limit = NSMaxRange(r)
        var lineEnd = r.location
        while lineEnd < limit, full.character(at: lineEnd) != 0x0A { lineEnd += 1 }
        let fenceLine = NSRange(location: r.location, length: lineEnd - r.location)
        guard fenceLine.length > 0 else { return }
        let lineText = full.substring(with: fenceLine)
        guard let langRange = lineText.range(of: language, options: .backwards) else { return }
        let nsLangRange = NSRange(langRange, in: lineText)
        let labelRange = NSRange(location: fenceLine.location + nsLangRange.location,
                                 length: nsLangRange.length)
        guard NSMaxRange(labelRange) <= full.length else { return }
        storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseSize), range: labelRange)
        storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentTertiary), range: labelRange)
    }

    // MARK: - Collapsing hidden markers

    /// Merges overlapping and adjacent ranges into a minimal covering set.
    ///
    /// Marker ranges are NOT disjoint. A nested blockquote `>> a` emits an
    /// outer `">> "` marker and an inner `"> "` marker that overlap, and two
    /// abutting markers (`**` immediately followed by `*`) produce ranges that
    /// touch. Applying attributes range-by-range would still be correct for
    /// `.font`, but the overlap makes the work quadratic in the worst case and
    /// makes any future non-idempotent attribute (a width reservation, a
    /// count) silently wrong. Coalescing first removes the whole class.
    ///
    /// Adjacent ranges are merged too (`<=`, not `<`): `a..<b` and `b..<c`
    /// describe one contiguous stretch of hidden syntax.
    static func coalesce(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted {
            $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound
                                           : $0.lowerBound < $1.lowerBound
        }
        var merged: [Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Makes `ranges` take no visual space, WITHOUT altering the text.
    ///
    /// A near-zero font rather than a zero font: AppKit treats a zero-point
    /// font as invalid and substitutes the system default, which would make
    /// hidden markers render at FULL size — the opposite of the intent.
    ///
    /// The document string is never touched. Collapsing is attributes and
    /// visibility only, so every offset the search index, the link graph and
    /// the MCP tools hold stays valid by construction. If this ever starts
    /// deleting or rewriting characters, a display concern has reached the
    /// document — after fourteen data-loss defects in M0/M1, that is the one
    /// trade this codebase does not make.
    static func collapse(_ ranges: [Range<Int>], in storage: NSTextStorage) {
        let length = storage.length
        let collapsedFont = NSFont.systemFont(ofSize: 0.01)
        storage.beginEditing()
        for range in coalesce(ranges) {
            let ns = NSRange(location: range.lowerBound, length: range.count)
            guard ns.location >= 0, ns.location + ns.length <= length else { continue }
            storage.addAttribute(.font, value: collapsedFont, range: ns)
            storage.addAttribute(.kern, value: CGFloat(0), range: ns)
        }
        storage.endEditing()
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
