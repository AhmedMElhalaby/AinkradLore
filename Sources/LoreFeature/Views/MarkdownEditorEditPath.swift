import AppKit
import SwiftUI
import AinkradAppKit

/// The EDIT path: what a keystroke costs, and the guard that stops a redraw
/// from paying for it twice.
///
/// Split out of `MarkdownEditor.swift` (AppKit wiring) and
/// `MarkdownEditorReveal.swift` (the caret path) because it is neither, and
/// because both of those files are at their length limit. What lives here is
/// the answer to M5 Task 10's measurement: typing re-rendered the whole
/// document, once from `textDidChange` and again from SwiftUI's `updateNSView`.
///
/// Two changes, in the order they were measured:
///
/// 1. `isRenderStale` — a redraw whose inputs are all unchanged does nothing.
/// 2. `renderStylesForEdit` — an edit re-attributes only the block it landed
///    in, or refuses and lets the caller do the whole document.
///
/// The counters (`applyStylesCalls`, `revealIndexBuilds`,
/// `lastEditTookFastPath`) exist so both claims are asserted rather than
/// argued: see `MarkdownEditorRedrawTests`, `MarkdownEditFastPathTests` and
/// `MarkdownTypingLagBenchmark`.
extension MarkdownEditor.Coordinator {
    // MARK: - Text

    /// Records WHERE the edit is about to happen, so `textDidChange` can
    /// shift the cached spans instead of re-parsing. Never vetoes an edit.
    ///
    /// A nil `replacementString` is an attributes-only change: there is no
    /// delta to shift by, so the cache is left to notice the mismatch.
    public func textView(_ tv: NSTextView, shouldChangeTextIn affected: NSRange,
                         replacementString: String?) -> Bool {
        // `tv.string` is still the PRE-edit text here, which is the only
        // moment the cache's currency can be checked against it. Spans that
        // did not describe the text before the edit cannot be shifted into
        // describing it after.
        //
        // It is also the only moment BOTH halves of the edit are readable —
        // what is going in, and what is coming out — which is what
        // `MarkdownEditorReveal`'s single-block fast path needs to decide
        // whether the edit can possibly have moved a block boundary. Once
        // `textDidChange` fires, the removed text is gone.
        pendingEdit = styleCache.describes(tv.string)
            ? replacementString.map {
                PendingEdit(range: affected, replacementLength: ($0 as NSString).length,
                            touchesBlockStructure:
                                Self.disturbsStructure($0)
                                || Self.disturbsStructure(
                                    (tv.string as NSString).substring(with: affected)))
              }
            : nil
        return true
    }

    /// What `shouldChangeTextIn` recorded, for `textDidChange` to consume.
    struct PendingEdit {
        let range: NSRange
        let replacementLength: Int
        /// Whether this half of the edit contains a character that could
        /// re-segment the document or re-scope a multi-line span, and so
        /// bars the single-block fast path. See `disturbsStructure`.
        let touchesBlockStructure: Bool
    }

    /// Characters whose arrival or departure can change something no
    /// single-block re-attribution could cover.
    ///
    /// - line terminators move block boundaries outright
    ///   (`MarkdownReveal.blocks` splits on blank lines);
    /// - a backtick or tilde can open or close a FENCE, whose span reaches
    ///   past every block between its ends.
    ///
    /// Applied to both the inserted and the removed text, because either
    /// direction changes the same things. Deliberately a character test
    /// rather than an analysis: it costs a scan of a one-character string
    /// on the hot path, it is impossible to get subtly wrong, and every
    /// false positive merely takes the full render that used to be
    /// unconditional.
    static func disturbsStructure(_ text: String) -> Bool {
        text.utf16.contains { $0 == 0x0A || $0 == 0x0D || $0 == 0x60 || $0 == 0x7E }
    }

    public func textDidChange(_ notification: Notification) {
        guard let tv = textView else { return }
        text.wrappedValue = tv.string
        var spansBefore: Int?
        if let edit = pendingEdit {
            spansBefore = styleCache.spans.count
            styleCache.shift(editedRange: edit.range,
                             delta: edit.replacementLength - edit.range.length,
                             newText: tv.string)
        }
        let edit = pendingEdit
        pendingEdit = nil
        // Renders the SHIFTED spans — no parse on the keystroke path. The
        // real parse lands one debounce later.
        //
        // `renderStylesForEdit` re-attributes only the block the edit
        // landed in, and returns false — falling back to the full,
        // whole-document render this used to do unconditionally — whenever
        // it cannot PROVE that is equivalent. See its doc comment for the
        // list of things it refuses to be clever about.
        let handled: Bool
        if let edit, let spansBefore {
            handled = renderStylesForEdit(edit, spansBefore: spansBefore)
        } else {
            handled = false
        }
        lastEditTookFastPath = handled
        if !handled { renderStyles() }
        scheduleParse()
        // The ONE place `completions` is called: a keystroke happened.
        refreshCompletions()
    }

    // MARK: - The redundant-redraw guard

    /// Whether what is on screen could differ from what a render would now
    /// produce.
    ///
    /// MEASURED, not assumed: a hosted editor runs `applyStyles()` exactly once
    /// per keystroke (`MarkdownEditorRedrawTests`), because `textDidChange`
    /// writes `text.wrappedValue` and SwiftUI then re-runs `updateNSView`,
    /// which calls it unconditionally. Together with `textDidChange`'s own
    /// render that was TWO full-document renders per typed character, the
    /// second recomputing byte for byte what the first had just written.
    ///
    /// Skipping is safe exactly when all three of a render's inputs are
    /// unchanged since the last one: the SPANS (identified by the string they
    /// describe), the TOKENS (every colour and font comes from them), and — in
    /// viewport mode only — the styled WINDOW, which follows the scroll.
    /// Selection is deliberately not in that list: reveal is maintained
    /// incrementally by `revealForSelectionChange` and does not come through
    /// here. Conservative in the only direction that matters: every answer
    /// it is not certain about is `true`, which costs a redundant render — the
    /// status quo — rather than showing stale attributes.
    func isRenderStale(for tv: NSTextView) -> Bool {
        guard let rendered = renderedSnapshot else { return true }
        guard rendered.tokens == tokens else { return true }
        // The spans on screen came from THIS string, and the cache still
        // describes it. Two O(n) string compares against a render that is
        // O(n) in the same n with a far larger constant — `apply` alone was
        // 52 ms where the compares are microseconds.
        guard rendered.text == tv.string, styleCache.describes(tv.string) else { return true }
        // Viewport mode styles a moving window, so an unchanged document can
        // still need re-styling after a scroll. (`restyleForViewportIfNeeded`
        // is the usual driver; this keeps the guard from swallowing the case
        // where a redraw arrives first.)
        if styleCache.isOverViewportCap {
            guard let last = lastViewportWindow,
                  NSEqualRanges(last, MarkdownStyleRenderer.viewportWindow(of: tv))
            else { return true }
        }
        return false
    }


    // MARK: - The single-block edit path

    /// Re-attributes ONLY the block the edit landed in, and returns whether it
    /// did. `false` means "I could not prove this was equivalent to a full
    /// render" and the caller must run `renderStyles()`.
    ///
    /// WHY. `renderStyles()` is O(document) in six places, and `textDidChange`
    /// called it per typed character: MEASURED at 9 ms per render on a
    /// 500-line note and 92 ms on a 5,000-line one, of which
    /// `MarkdownStyleRenderer.apply` — a full-range `setAttributes` plus a walk
    /// of every span in the document — is ~60%. A one-character edit can only
    /// change the attributes of ONE block; a 2,000-line note has 728. The caret
    /// path has re-attributed exactly the blocks that changed since M5 Task 8
    /// (`restyleBlock`, asserted by
    /// `test_arrowingThroughALargeDocumentReAttributesOnlyTwoBlocks`); this
    /// gives the EDIT path the same treatment, through the same machinery
    /// rather than a second implementation of it.
    ///
    /// CORRECTNESS. The bar is byte-identical attributes, not "close enough" —
    /// see `MarkdownEditFastPathTests`, which asserts exactly that against a
    /// full render for a range of realistic edits. Everything this needs is
    /// therefore CHECKED rather than argued:
    ///
    /// 1. The cache was current before the edit and shifted cleanly — the
    ///    caller only gets here with a `PendingEdit`, which is `nil` otherwise.
    /// 2. `shift` DROPPED no span. It uses `compactMap` and discards spans a
    ///    deletion collapsed, which would silently re-index every bucket in
    ///    `revealIndex.spansByBlock`. Compared by count, from before the shift.
    /// 3. The edit contains no line terminator and no fence character, in
    ///    EITHER direction — see `Coordinator.disturbsStructure`.
    /// 4. The recomputed block segmentation equals the old one moved by the
    ///    edit's delta. This is the load-bearing check, and the reason 3 can
    ///    afford to be a crude character test: rather than reasoning about
    ///    which edits can re-segment a document, the segmentation is simply
    ///    recomputed (a character scan — 1.5 ms on the 5,000-line fixture,
    ///    against the 92 ms it avoids) and required to match. Anything that
    ///    moved a boundary, for any reason anyone thought of or did not, fails
    ///    here and takes the full render.
    /// 5. No span overlaps the edited block without being bucketed INTO it.
    ///    This is exactly `restyleBlock`'s stated precondition ("nothing they
    ///    style can reach past the block's ends"), which a fenced code block
    ///    containing a blank line violates — its span starts in one block and
    ///    covers several. Restyling a later one would clear its code styling
    ///    and have no span left to restore it.
    /// 6. The document is under the viewport cap, so the render is not
    ///    windowed. Above it, styling follows the scroll and a block-scoped
    ///    update cannot maintain that.
    ///
    /// What the fast path still does in full, because each is cheap and each is
    /// a whole-document fact: the block list, list depths, the embed index, the
    /// writing direction, and the drawn block backgrounds — whose regions are
    /// derived from span POSITIONS and would otherwise be left painting code
    /// panels at pre-edit offsets.
    ///
    /// And when this is wrong anyway, the 150 ms debounced parse lands a full,
    /// correct render on top: a mis-styled frame, never a mis-styled document.
    /// That is a safety net, not the argument — the checks above are.
    func renderStylesForEdit(_ edit: MarkdownEditor.Coordinator.PendingEdit,
                             spansBefore: Int) -> Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        // 3, 2, 6.
        guard !edit.touchesBlockStructure else { return false }
        guard styleCache.spans.count == spansBefore else { return false }
        guard !styleCache.isOverViewportCap, !styleCache.isOverHardCap else { return false }
        // Nothing rendered yet — there is no previous picture to patch.
        guard renderedSnapshot != nil, !revealIndex.blocks.isEmpty else { return false }

        // 4. The old segmentation, moved by this edit, must be what the text
        // now actually segments into.
        let delta = edit.replacementLength - edit.range.length
        let limit = (tv.string as NSString).length
        let shifted = revealIndex.blocks.map { block in
            movedOffset(block.lowerBound, start: edit.range.location, delta: delta, limit: limit)
                ..< movedOffset(block.upperBound, start: edit.range.location,
                                delta: delta, limit: limit)
        }
        let fresh = MarkdownReveal.blocks(in: tv.string)
        guard shifted == fresh else { return false }

        guard let block = MarkdownEditorReveal.blockIndex(of: edit.range.location, in: fresh)
        else { return false }
        let blockRange = fresh[block]

        // 5. Every span touching this block must belong to it.
        let bucket = Set(revealIndex.spansByBlock[block])
        for (position, span) in styleCache.spans.enumerated()
        where span.range.lowerBound < blockRange.upperBound
            && span.range.upperBound > blockRange.lowerBound {
            guard bucket.contains(position) else { return false }
        }

        // Proven. Everything below is the full render's whole-document
        // bookkeeping — all of it cheap — with the ONE expensive step,
        // re-attributing the document, narrowed to the block that changed.
        revealIndex = MarkdownEditorReveal.Index(
            blocks: fresh, spansByBlock: revealIndex.spansByBlock,
            depths: MarkdownListDepth.depths(of: styleCache.spans))
        revealIndexBuilds += 1
        rebuildEmbedIndex()
        documentWritingDirection = EmbedGeometry.strongWritingDirection(of: tv.string)
            ?? .leftToRight
        // Reveal, computed the way a FULL render computes it — from the live
        // selection and focus against the fresh blocks — rather than read from
        // `revealedBlockIndices`. That field is maintained by the caret path,
        // and during an edit AppKit posts its selection change against the
        // PRE-edit block list, so trusting it here collapsed the markers of the
        // very block being typed in: the first version of this method showed
        // `**bold**` with its asterisks hidden while the caret sat inside them,
        // which the equivalence test caught immediately.
        let focused = isTextViewFocused
        let was = revealedBlockIndices
        let now = focused
            ? MarkdownEditorReveal.revealedBlockIndices(fresh, selection: tv.selectedRange())
            : 0..<0
        lastRevealFocus = focused
        revealedBlockIndices = now
        // The block that changed, plus any whose reveal state flipped — the
        // same symmetric difference the caret path uses. Block COUNT is
        // unchanged (checked above), so indices from before the edit are still
        // comparable with these.
        var toRestyle = Set(now).symmetricDifference(Set(was))
        toRestyle.insert(block)
        for index in toRestyle.sorted() {
            restyleBlock(index, revealed: now.contains(index), in: storage)
        }
        // Keeps `revealedEmbedSpans` in step, exactly as the caret path does,
        // so the next caret move compares against the truth.
        revealEmbedsForSelectionChange(in: storage)
        if let linkView = tv as? LinkTextView {
            linkView.blockBackgroundPalette = MarkdownBlockBackgrounds.Palette(tokens: tokens)
            linkView.blockBackgrounds =
                MarkdownBlockBackgrounds.regions(for: styleCache.spans,
                                                 length: storage.length,
                                                 limitedTo: nil,
                                                 in: storage.string as NSString)
        }
        stylingNotice?.isHidden = !styleCache.isOverHardCap
        stylingNotice?.textColor = NSColor(tokens.accentSecondary)
        renderedSnapshot = (tv.string, tokens)
        // The drawn decoration — code panels, quote bars, substituted list
        // markers — lives in the gutter, outside the glyph rects an attribute
        // change dirties, so it has to be asked for explicitly.
        tv.needsDisplay = true
        return true
    }

    /// `MarkdownStyleCache.shift`'s offset rule, applied to block bounds.
    ///
    /// Deliberately the SAME rule, not a similar one: blocks and spans have to
    /// move together or the buckets stop describing the blocks they index. An
    /// offset at or before the edit stays put; one after it moves by the delta.
    func movedOffset(_ offset: Int, start: Int, delta: Int, limit: Int) -> Int {
        guard offset > start else { return min(offset, limit) }
        return min(max(start, offset + delta), limit)
    }
}
