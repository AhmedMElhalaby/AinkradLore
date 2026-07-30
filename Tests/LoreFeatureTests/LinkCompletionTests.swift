import XCTest
@testable import LoreFeature

final class LinkCompletionTests: XCTestCase {
    func test_detectsPrefixAfterOpenBrackets() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "see [[Des", caret: 9), "Des")
    }

    func test_returnsEmptyPrefixImmediatelyAfterBrackets() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "see [[", caret: 6), "")
    }

    func test_nilWhenLinkIsAlreadyClosed() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "see [[Design]] x", caret: 16))
    }

    func test_nilWhenNoBracketsBeforeCaret() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "plain text", caret: 5))
    }

    func test_stopsAtNewline() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "[[\nDesign", caret: 9))
    }

    func test_usesTheNearestOpenBrackets() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "[[A]] and [[B", caret: 13), "B")
    }

    // MARK: - Click-to-open span detection

    func test_targetUnderCaretInsideSpan() {
        XCTAssertEqual(LinkCompletionContext.target(in: "see [[Design]] x", at: 8), "Design")
    }

    func test_targetAtSpanEdges() {
        // Just inside the opening brackets and just before the closing ones.
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 2), "Design")
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 8), "Design")
    }

    func test_targetNilOutsideAnySpan() {
        XCTAssertNil(LinkCompletionContext.target(in: "see [[Design]] x", at: 15))
        XCTAssertNil(LinkCompletionContext.target(in: "plain text", at: 3))
    }

    func test_targetDoesNotCrossLines() {
        XCTAssertNil(LinkCompletionContext.target(in: "[[Design\n]] x", at: 4))
    }

    func test_targetKeepsRawAliasAndHeadingSyntax() {
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design#Goals|why]]", at: 5),
                       "Design#Goals|why")
    }

    func test_targetNilForEmptySpan() {
        XCTAssertNil(LinkCompletionContext.target(in: "[[]]", at: 2))
    }
}
