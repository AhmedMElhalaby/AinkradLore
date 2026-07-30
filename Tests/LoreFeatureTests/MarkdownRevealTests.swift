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
