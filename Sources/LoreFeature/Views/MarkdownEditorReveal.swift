import AppKit
import SwiftUI
import AinkradAppKit

/// Where the text column sits inside the editor's width.
///
/// A value, not a view: the owner's complaint was that text "runs edge to
/// edge", and the numbers that fix it are worth asserting directly rather than
/// through a view host. `MarkdownEditor` had `NSSize(width: 16, height: 16)`
/// hard-coded while `MarkdownTheme.contentInset` and `.maxMeasure` sat
/// declared and unused.
enum MarkdownEditorLayout {

    /// The `textContainerInset` for a text view `viewWidth` points wide.
    ///
    /// One symmetric inset does both jobs. `widthTracksTextView` makes the
    /// container `viewWidth - 2 * inset`, so growing the inset both narrows the
    /// column and CENTRES it — there is no separate centring step to get wrong,
    /// and no second coordinate source for `MarkdownBlockBackgrounds` to
    /// disagree with.
    ///
    /// The theme's inset is a FLOOR, never a target: on a narrow pane the cap
    /// is not binding and the margin must not shrink below what makes the text
    /// comfortable.
    static func containerInset(forViewWidth viewWidth: CGFloat,
                               theme: MarkdownTheme) -> NSSize {
        var horizontal = theme.contentInset
        if let measure = theme.maxMeasure {
            horizontal = max(horizontal, (viewWidth - measure) / 2)
        }
        // Clamped so a view narrower than twice the inset still leaves a
        // positive column rather than an inverted one.
        horizontal = min(horizontal, max(0, viewWidth / 2 - 1))
        return NSSize(width: horizontal, height: theme.contentInset)
    }
}

/// The selection-driven half of Live Preview.
///
/// `MarkdownReveal` answers "which markers are hidden". This answers the
/// cheaper question the editor asks on EVERY arrow-key press: has anything
/// about the reveal actually changed? Recomputing hidden markers costs a walk
/// over every span in the document; recomputing revealed BLOCKS costs a walk
/// over the blocks, of which there are orders of magnitude fewer. When the
/// answer is unchanged — which is every keypress that does not cross a blank
/// line — the editor does no styling work at all.
///
/// Neither path parses. Block ranges come from `MarkdownReveal.blocks(in:)`,
/// which is a character scan, and they are recomputed only when the text is
/// re-rendered.
enum MarkdownEditorReveal {

    /// Everything the caret path needs, derived once per TEXT change.
    ///
    /// The point of this type is that `revealForSelectionChange` may touch none
    /// of the document: the block ranges are here rather than rescanned, the
    /// spans are already bucketed by block so no walk over all spans is needed
    /// to find the two that matter, and list depths — which are global, being
    /// derived from containment — are computed once so a per-block restyle
    /// cannot disagree with a full one.
    struct Index {
        let blocks: [Range<Int>]
        /// Positions into the coordinator's `spans`, bucketed by block. A span
        /// belongs to the block containing its start; markdown spans do not
        /// cross a blank line, so that is also the block containing all of it.
        let spansByBlock: [[Int]]
        /// Nesting depth per span, aligned by index. See `MarkdownListDepth`.
        let depths: [Int]

        static let empty = Index(blocks: [], spansByBlock: [], depths: [])
    }

    /// Builds the index for `text` and `spans`. O(text) once, on a text change
    /// — never on a caret move.
    static func index(text: String, spans: [StyleSpan]) -> Index {
        let blocks = MarkdownReveal.blocks(in: text)
        var buckets = [[Int]](repeating: [], count: blocks.count)
        for (position, span) in spans.enumerated() {
            guard let block = blockIndex(of: span.range.lowerBound, in: blocks) else { continue }
            buckets[block].append(position)
        }
        return Index(blocks: blocks, spansByBlock: buckets,
                     depths: MarkdownListDepth.depths(of: spans))
    }

    /// The block containing `offset`, by binary search. Blocks are sorted and
    /// contiguous, which is what makes this — and `revealedBlockIndices` —
    /// logarithmic rather than a scan.
    static func blockIndex(of offset: Int, in blocks: [Range<Int>]) -> Int? {
        var low = 0, high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if offset < blocks[mid].lowerBound { high = mid - 1 }
            else if offset >= blocks[mid].upperBound { low = mid + 1 }
            else { return mid }
        }
        // Past the last block's end — an offset at the very end of the
        // document belongs to the last block rather than to nothing.
        return blocks.isEmpty ? nil : min(max(low, 0), blocks.count - 1)
    }

    /// The INDICES of the blocks the selection touches.
    ///
    /// Contiguous, and therefore a range rather than a set: blocks tile the
    /// document end to end, so the blocks a selection touches are exactly those
    /// between the one holding its start and the one holding its end. A caret
    /// resting exactly on a boundary belongs to both adjacent blocks — the
    /// inclusive rule `MarkdownReveal.hiddenMarkers` uses — which this
    /// preserves by widening one step at a boundary rather than flickering
    /// between two answers.
    static func revealedBlockIndices(_ blocks: [Range<Int>],
                                     selection: NSRange) -> Range<Int> {
        guard !blocks.isEmpty else { return 0..<0 }
        let lower = selection.location
        let upper = lower + max(selection.length, 0)
        guard var first = blockIndex(of: lower, in: blocks),
              var last = blockIndex(of: upper, in: blocks) else { return 0..<0 }
        if first > 0, blocks[first].lowerBound == lower { first -= 1 }
        if last < blocks.count - 1, blocks[last].upperBound == upper { last += 1 }
        return first..<(last + 1)
    }

    /// The blocks the selection touches, and therefore the blocks whose
    /// markers are shown.
    ///
    /// The value-level statement of the same rule, kept for tests and for
    /// callers that want the ranges rather than their positions.
    static func revealedBlocks(_ blocks: [Range<Int>],
                               selection: NSRange) -> [Range<Int>] {
        let lower = selection.location
        let upper = selection.location + max(selection.length, 0)
        return blocks.filter { lower <= $0.upperBound && $0.lowerBound <= upper }
    }
}

extension MarkdownEditor.Coordinator {

    // MARK: - Styling

    /// The one entry point for callers that do not know whether the text
    /// changed: `makeNSView`, and `updateNSView` on every ancestor redraw.
    ///
    /// Parses ONLY when the cached spans describe a different string than
    /// the one on screen — which, after a keystroke, they do not, because
    /// `textDidChange` has already shifted them. A redraw therefore costs a
    /// render and nothing else.
    func applyStyles() {
        guard let tv = textView else { return }
        if !styleCache.describes(tv.string) { styleCache.reparse(tv.string) }
        renderStyles()
    }

    /// Applies the cached spans. No parse, ever.
    func renderStyles() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let window = styleCache.isOverViewportCap
            ? MarkdownStyleRenderer.viewportWindow(of: tv) : nil
        lastViewportWindow = window
        let theme = MarkdownTheme(tokens: tokens)
        MarkdownStyleRenderer.apply(styleCache.spans, to: storage,
                                    tokens: tokens, theme: theme,
                                    limitedTo: window)
        // Reveal rides the SAME pass as the attributes, and must come after
        // them: `apply` sets fonts over the whole string, so collapsing first
        // would be immediately overwritten.
        //
        // THE ONLY place the index is built, and this runs on a text change or
        // a redraw — never on a caret move. `MarkdownReveal.blocks(in:)` is a
        // scan of the whole string, so calling it from the selection path would
        // put an O(document) cost on every arrow key.
        revealIndex = MarkdownEditorReveal.index(text: tv.string, spans: styleCache.spans)
        revealIndexBuilds += 1
        collapseHiddenMarkers(in: storage, window: window)
        // Code panels and quote bars are DRAWN, not attributed — see
        // `MarkdownBlockBackgrounds`. Refreshed from the same spans in the
        // same pass, so the decoration can never describe older text than
        // the attributes do. Clipped to the SAME window the attributes were,
        // so a panel is never painted behind text that was left unstyled.
        if let linkView = tv as? LinkTextView {
            linkView.blockBackgroundPalette = MarkdownBlockBackgrounds.Palette(tokens: tokens)
            linkView.blockBackgrounds =
                MarkdownBlockBackgrounds.regions(for: styleCache.spans,
                                                 length: storage.length,
                                                 limitedTo: window)
        }
        stylingNotice?.isHidden = !styleCache.isOverHardCap
        stylingNotice?.textColor = NSColor(tokens.accentSecondary)
    }

    /// Hides the markers of every block the selection is NOT in, and records
    /// the reveal state that `revealForSelectionChange` compares against.
    ///
    /// The whole-document version, run only as part of a full render.
    private func collapseHiddenMarkers(in storage: NSTextStorage, window: NSRange?) {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        revealedBlockIndices = MarkdownEditorReveal.revealedBlockIndices(
            revealIndex.blocks, selection: selection)
        var hidden = MarkdownReveal.hiddenMarkers(spans: styleCache.spans,
                                                  selection: selection,
                                                  blocks: revealIndex.blocks)
        if let window {
            hidden = hidden.filter {
                $0.lowerBound < NSMaxRange(window) && $0.upperBound > window.location
            }
        }
        MarkdownStyleRenderer.collapse(hidden, in: storage)
    }

    /// Called from `textViewDidChangeSelection` — i.e. on every arrow key.
    ///
    /// Costs, in order of how often each is reached:
    ///
    /// 1. Caret still inside the same block — two binary searches over the
    ///    cached block list and an equality check. No parse, no scan of the
    ///    text, no attribute written. This is nearly every keypress.
    /// 2. Caret crossed a boundary — the blocks that ENTERED and LEFT reveal
    ///    are re-attributed, and nothing else is. Two blocks, from spans
    ///    already bucketed per block, over character ranges bounded by the
    ///    blocks themselves.
    ///
    /// What it deliberately does NOT do is call `renderStyles()`, which is what
    /// the first version of this did. `MarkdownStyleRenderer.apply` clears the
    /// whole document before styling — correct for a text change, ruinous for
    /// an arrow key — and `MarkdownReveal.blocks(in:)` rescans the entire
    /// string. Blocks are blank-line-separated paragraphs, so arrowing down
    /// ordinary prose crosses one every few keypresses; the full path would
    /// have restyled the note each time. Block ranges depend only on the TEXT
    /// and are rebuilt only when the text is rendered.
    func revealForSelectionChange() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        guard !revealIndex.blocks.isEmpty else { return }
        let selection = tv.selectedRange()
        let now = MarkdownEditorReveal.revealedBlockIndices(revealIndex.blocks,
                                                            selection: selection)
        let was = revealedBlockIndices
        guard now != was else { return }
        revealedBlockIndices = now

        // Exactly the blocks whose reveal state flipped: those in one range and
        // not the other. Both are contiguous, so this is a handful of indices
        // even when a selection is dragged across many blocks at once.
        let changed = Set(now).symmetricDifference(Set(was))
        for block in changed.sorted() {
            restyleBlock(block, revealed: now.contains(block), in: storage)
        }
    }

    /// Re-attributes ONE block and re-hides its markers if it is not revealed.
    ///
    /// A marker that must REAPPEAR cannot be un-collapsed in place — the font it
    /// should return to is a function of its enclosing spans — so the block is
    /// rebuilt from the cached spans. Still no parse, and still nothing outside
    /// this block is touched.
    private func restyleBlock(_ block: Int, revealed: Bool, in storage: NSTextStorage) {
        guard block >= 0, block < revealIndex.blocks.count else { return }
        let range = revealIndex.blocks[block]
        let ns = NSRange(location: range.lowerBound, length: range.count)
        MarkdownStyleRenderer.restyle(styleCache.spans,
                                      at: revealIndex.spansByBlock[block],
                                      depths: revealIndex.depths,
                                      in: ns, to: storage,
                                      tokens: tokens,
                                      theme: MarkdownTheme(tokens: tokens))
        guard !revealed else { return }
        let hidden = revealIndex.spansByBlock[block].compactMap { index -> Range<Int>? in
            guard index < styleCache.spans.count,
                  case .marker = styleCache.spans[index].kind else { return nil }
            return styleCache.spans[index].range
        }
        MarkdownStyleRenderer.collapse(hidden, in: storage)
    }

    // MARK: - Container geometry

    /// Re-centres the text column for a view `width` points wide.
    ///
    /// Called on every width change, because the inset is a function of the
    /// width: without this the column would keep the margins it was born with
    /// and drift off-centre as the window resizes.
    func applyContainerInset(forWidth width: CGFloat) {
        guard let tv = textView else { return }
        let inset = MarkdownEditorLayout.containerInset(
            forViewWidth: width, theme: MarkdownTheme(tokens: tokens))
        guard tv.textContainerInset != inset else { return }
        tv.textContainerInset = inset
        // The drawn decoration is positioned from the container, so it has to
        // be repainted when the container moves.
        tv.needsDisplay = true
    }

    // MARK: - Parsing

    /// Re-arms the debounce. Only its firing parses, so a burst of typing
    /// costs one parse rather than one per character.
    func scheduleParse() {
        parseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.parseDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.parseNow() }
        }
        parseTimer = timer
        // `.common` so the parse still lands while the user is scrolling or
        // holding a menu open, rather than after they stop.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Parses OFF the main actor and applies the result back on it.
    ///
    /// This used to be a synchronous parse on the main actor, called from a
    /// main-run-loop timer. On a large note that is measured in whole
    /// seconds, and a main-actor second is not lag — it is a beachball, once
    /// per pause in typing. The parse itself is pure (`derive` touches no
    /// AppKit and no editor state), so the only thing that must stay on the
    /// main actor is applying the answer.
    ///
    /// Two guards keep a slow parse from styling the wrong characters:
    ///
    /// 1. `generation` — a newer parse having been started makes this one's
    ///    result garbage, even if the text looks right.
    /// 2. the SNAPSHOT check — the spans index `snapshot` and nothing else,
    ///    so they are installed only if the view still holds exactly that
    ///    string. This is the same identity rule `describes(_:)` encodes,
    ///    applied across the hop.
    ///
    /// When the text HAS moved on, nothing is applied and nothing is
    /// re-armed here: the edit that moved it went through `textDidChange`,
    /// which armed the debounce already.
    func parseNow() {
        parseTimer = nil
        guard let tv = textView else { return }
        let snapshot = tv.string
        guard styleCache.isStale || !styleCache.describes(snapshot) else { return }
        parseGeneration += 1
        let generation = parseGeneration
        Task.detached(priority: .userInitiated) {
            let derived = MarkdownStyleCache.derive(snapshot)
            await MainActor.run { [weak self] in
                self?.applyParsed(derived, of: snapshot, generation: generation)
            }
        }
    }

    private func applyParsed(_ derived: MarkdownStyleCache.Derived,
                             of snapshot: String, generation: Int) {
        guard generation == parseGeneration,
              let tv = textView, tv.string == snapshot else { return }
        styleCache.adopt(derived, for: snapshot)
        renderStyles()
    }

    /// In viewport mode the styled range follows the scroll, so scrolling
    /// has to re-render — but only when the window actually moved, since
    /// this fires continuously during a drag.
    func restyleForViewportIfNeeded() {
        guard styleCache.isOverViewportCap, let tv = textView else { return }
        let window = MarkdownStyleRenderer.viewportWindow(of: tv)
        if let last = lastViewportWindow, NSEqualRanges(last, window) { return }
        renderStyles()
    }
}
