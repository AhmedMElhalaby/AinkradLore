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

    /// The blocks the selection touches, and therefore the blocks whose
    /// markers are shown.
    ///
    /// The predicate is `MarkdownReveal.hiddenMarkers`' own reveal rule, stated
    /// over blocks alone: inclusive at both ends, so a caret resting exactly on
    /// a boundary reveals rather than flickering between two answers.
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
        revealBlocks = MarkdownReveal.blocks(in: tv.string)
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
    private func collapseHiddenMarkers(in storage: NSTextStorage, window: NSRange?) {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        revealedBlocks = MarkdownEditorReveal.revealedBlocks(revealBlocks,
                                                             selection: selection)
        var hidden = MarkdownReveal.hiddenMarkers(spans: styleCache.spans,
                                                  selection: selection,
                                                  blocks: revealBlocks)
        if let window {
            hidden = hidden.filter {
                $0.lowerBound < NSMaxRange(window) && $0.upperBound > window.location
            }
        }
        MarkdownStyleRenderer.collapse(hidden, in: storage)
    }

    /// Called from `textViewDidChangeSelection` — i.e. on every arrow key.
    ///
    /// Deliberately does NOT parse and, in the common case, does not
    /// re-attribute either. Re-attributing is only correct when a marker has to
    /// come back, and a marker only comes back when the caret crosses into a
    /// different block; while the caret stays put in one block this costs a
    /// filter over `revealBlocks` and a comparison. Task 11 asserts that a
    /// caret move costs zero markdown parses, which this satisfies by
    /// construction: the only inputs are the cached spans and the cached
    /// block ranges.
    func revealForSelectionChange() {
        guard let tv = textView else { return }
        let nowRevealed = MarkdownEditorReveal.revealedBlocks(
            revealBlocks, selection: tv.selectedRange())
        guard nowRevealed != revealedBlocks else { return }
        // A marker that must REAPPEAR cannot be un-collapsed in place — the
        // font it should return to is a function of its enclosing spans — so
        // the attributes are re-derived from the cache. Still no parse.
        renderStyles()
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
