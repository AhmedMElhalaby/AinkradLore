import XCTest
@testable import LoreFeature

final class MarkdownExtensionsTests: XCTestCase {

    /// Scans through the model so the code mask is the real one, not a
    /// hand-built approximation that could drift from what ships.
    private func scan(_ body: String) -> [MarkdownExtensions.Span] {
        MarkdownDocumentModel(body: body).extensionSpans
    }

    func test_scan_emptyDocument_returnsNoSpans() {
        XCTAssertTrue(scan("").isEmpty)
    }

    func test_scan_plainProse_returnsNoSpans() {
        XCTAssertTrue(scan("just some ordinary prose, nothing to see").isEmpty)
    }

    func test_highlight_wellFormed() {
        let spans = scan("a ==lit== b")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.kind, .highlight)
        XCTAssertEqual(spans.first?.range, 2..<9)     // ==lit==
        XCTAssertEqual(spans.first?.content, 4..<7)   // lit
    }

    func test_highlight_emptyContentEmitsNothing() {
        XCTAssertTrue(scan("a ==== b").isEmpty)
    }

    func test_highlight_unclosedEmitsNothing() {
        XCTAssertTrue(scan("a ==lit b").isEmpty)
    }

    func test_highlight_doesNotCrossLines() {
        // Obsidian's own behaviour: a highlight is single-line.
        XCTAssertTrue(scan("a ==lit\nmore== b").isEmpty)
    }

    func test_highlight_insideCodeFenceEmitsNothing() {
        XCTAssertTrue(scan("```\n==not a highlight==\n```").isEmpty)
    }

    func test_highlight_insideInlineCodeEmitsNothing() {
        XCTAssertTrue(scan("a `==no==` b").isEmpty)
    }

    func test_highlight_twoOnOneLine() {
        XCTAssertEqual(scan("==a== and ==b==").count, 2)
    }

    func test_highlight_emojiBeforeDoesNotShiftRange() {
        // UTF-16: the emoji is two units, so `==` starts at 3, not 2.
        let spans = scan("🎈 ==lit==")
        XCTAssertEqual(spans.first?.range, 3..<10)
    }
}
