import AppKit
import XCTest
@testable import LoreFeature

final class MarkdownRevealTests: XCTestCase {

    private func hidden(_ body: String, selection: NSRange) -> [Range<Int>] {
        let model = MarkdownDocumentModel(body: body)
        return MarkdownReveal.hiddenMarkers(spans: model.styleSpans,
                                            selection: selection,
                                            blocks: MarkdownReveal.blocks(in: body))
    }

    /// With the caret elsewhere, every marker is hidden — this is the clean
    /// reading state.
    func test_markersAreHiddenWhenTheSelectionIsInAnotherBlock() {
        let body = "**bold**\n\nplain paragraph"
        let caret = NSRange(location: (body as NSString).length - 1, length: 0)
        XCTAssertFalse(hidden(body, selection: caret).isEmpty)
    }

    /// Caret inside the block: that block's markers come back so the user can
    /// edit the syntax they are standing in.
    func test_markersRevealWhenTheSelectionIsInsideTheirBlock() {
        let body = "**bold**\n\nplain paragraph"
        XCTAssertTrue(hidden(body, selection: NSRange(location: 3, length: 0)).isEmpty)
    }

    /// Reveal is BLOCK-scoped, not line-scoped. Obsidian reveals per line,
    /// which splits a multi-line emphasis span mid-word and looks broken.
    func test_revealIsBlockScopedSoAMultiLineSpanRevealsWholly() {
        let body = "**bold\nacross lines**\n\nother"
        // Caret on the FIRST line of the span; the marker on the SECOND line
        // must reveal too.
        XCTAssertTrue(hidden(body, selection: NSRange(location: 2, length: 0)).isEmpty)
    }

    /// A selection spanning two blocks reveals both.
    func test_aSelectionCrossingBlocksRevealsBoth() {
        let body = "**a**\n\n*b*"
        let whole = NSRange(location: 0, length: (body as NSString).length)
        XCTAssertTrue(hidden(body, selection: whole).isEmpty)
    }

    /// Only the touched block reveals — the other keeps its markers hidden.
    func test_anUntouchedBlockKeepsItsMarkersHidden() {
        let body = "**a**\n\n*b*"
        let inFirst = NSRange(location: 1, length: 0)
        let stillHidden = hidden(body, selection: inFirst)
        XCTAssertEqual(stillHidden.count, 2, "the emphasis pair in the second block")
    }

    /// A CRLF document with a single line break and no blank line is ONE
    /// block. "\r\n" is one line terminator, not a blank-line marker.
    func test_aSingleCRLFLineBreakIsNotABlankLine() {
        let body = "para one line a\r\npara one line b"
        XCTAssertEqual(MarkdownReveal.blocks(in: body).count, 1)
    }

    /// A genuine blank line in CRLF form ("\r\n\r\n") splits into TWO blocks.
    func test_aCRLFBlankLineSplitsIntoTwoBlocks() {
        let body = "para one\r\n\r\npara two"
        XCTAssertEqual(MarkdownReveal.blocks(in: body).count, 2)
    }

    /// A lone "\r" (old Mac line ending) behaves the same as "\n": one
    /// terminator, and two in a row is a blank line.
    func test_aLoneCarriageReturnBehavesLikeANewline() {
        let single = "para one line a\rpara one line b"
        XCTAssertEqual(MarkdownReveal.blocks(in: single).count, 1)

        let blank = "para one\r\rpara two"
        XCTAssertEqual(MarkdownReveal.blocks(in: blank).count, 2)
    }

    /// Mixed line endings within one document are each counted as a single
    /// terminator, not per-unit.
    func test_mixedLineEndingsAreCountedAsSingleTerminators() {
        let body = "line a\r\nline b\nline c\r\n\r\nline d"
        XCTAssertEqual(MarkdownReveal.blocks(in: body).count, 2)
    }

    /// The block-scoped multi-line reveal guarantee holds in a CRLF document:
    /// the CRLF analogue of test_revealIsBlockScopedSoAMultiLineSpanRevealsWholly.
    func test_revealIsBlockScopedAcrossACRLFLineBreak() {
        let body = "**bold\r\nacross lines**\r\n\r\nother"
        // Caret on the FIRST line of the span; the marker on the SECOND line
        // must reveal too, because CRLF must not fracture the block.
        XCTAssertTrue(hidden(body, selection: NSRange(location: 2, length: 0)).isEmpty)
    }
}

@MainActor
extension MarkdownRevealTests {

    /// THE constraint of this milestone: collapsing changes attributes only.
    /// If this ever fails, a display concern has reached the document — and
    /// after fourteen data-loss defects in M0/M1, that is not a trade we make.
    func test_collapsingNeverChangesTheDocumentText() {
        let body = "**bold** and *italic*"
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.collapse([0..<2, 6..<8], in: storage)
        XCTAssertEqual(storage.string, body)
    }

    /// Collapsed markers must take no width.
    func test_collapsedMarkersHaveEffectivelyZeroWidth() throws {
        let storage = NSTextStorage(string: "**bold**")
        MarkdownStyleRenderer.collapse([0..<2], in: storage)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertLessThan(try XCTUnwrap(font).pointSize, 0.1)
        let kern = storage.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(try XCTUnwrap(kern), 0, accuracy: 0.001)
    }

    /// Uncollapsed text is untouched — collapse must be surgical.
    func test_collapseLeavesNeighbouringTextAlone() throws {
        let storage = NSTextStorage(string: "**bold**")
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15),
                             range: NSRange(location: 0, length: 8))
        MarkdownStyleRenderer.collapse([0..<2], in: storage)
        let font = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertEqual(try XCTUnwrap(font).pointSize, 15, accuracy: 0.01)
    }

    /// Marker ranges are NOT disjoint — a nested blockquote emits an outer and
    /// an inner marker that overlap — so `collapse` coalesces before applying.
    func test_overlappingAndAdjacentRangesCoalesce() {
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([0..<3, 0..<2]), [0..<3])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([2..<4, 0..<2]), [0..<4])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([5..<7, 0..<2]), [0..<2, 5..<7])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([1..<4, 2..<3]), [1..<4])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([3..<3, 1..<2]), [1..<2])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([]), [])
    }

    /// A nested blockquote really does produce overlapping markers; collapsing
    /// them must still hide exactly the syntax and leave the text alone.
    func test_nestedBlockQuoteMarkersOverlapAndStillCollapse() throws {
        let body = ">> quoted"
        let model = MarkdownDocumentModel(body: body)
        let markers = model.styleSpans.compactMap { span -> Range<Int>? in
            if case .marker = span.kind { return span.range }
            return nil
        }
        XCTAssertFalse(markers.isEmpty)
        let storage = NSTextStorage(string: body)
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15),
                             range: NSRange(location: 0, length: (body as NSString).length))
        MarkdownStyleRenderer.collapse(markers, in: storage)
        XCTAssertEqual(storage.string, body)
        let head = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertLessThan(try XCTUnwrap(head).pointSize, 0.1)
        let tail = storage.attribute(.font, at: (body as NSString).length - 1,
                                     effectiveRange: nil) as? NSFont
        XCTAssertEqual(try XCTUnwrap(tail).pointSize, 15, accuracy: 0.01)
    }

    /// Out-of-bounds ranges are skipped, not trapped, and never touch the text.
    func test_collapseIgnoresOutOfBoundsRanges() {
        let body = "abc"
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.collapse([2..<99, -4 ..< -1], in: storage)
        XCTAssertEqual(storage.string, body)
    }

    /// End to end: what `hiddenMarkers` reports, `collapse` hides — and the
    /// document text is identical afterwards.
    func test_hiddenMarkersCollapseWithoutTouchingTheDocument() {
        let body = "**bold**\n\nplain paragraph"
        let caret = NSRange(location: (body as NSString).length - 1, length: 0)
        let ranges = hidden(body, selection: caret)
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.collapse(ranges, in: storage)
        XCTAssertEqual(storage.string, body)
        XCTAssertEqual((storage.string as NSString).length, (body as NSString).length)
    }
}
