import XCTest
@testable import LoreFeature

final class MarkdownStylerTests: XCTestCase {
    func test_detectsHeadingLevel() {
        let spans = MarkdownStyler.spans(in: "## Title")
        XCTAssertEqual(spans.first?.kind, .heading(2))
    }
    func test_detectsBoldAndItalic() {
        let kinds = MarkdownStyler.spans(in: "a **b** and *c*").map(\.kind)
        XCTAssertTrue(kinds.contains(.bold))
        XCTAssertTrue(kinds.contains(.italic))
    }
    func test_detectsInlineCode() {
        XCTAssertTrue(MarkdownStyler.spans(in: "run `ls`").map(\.kind).contains(.code))
    }
    func test_detectsCheckbox() {
        XCTAssertTrue(MarkdownStyler.spans(in: "- [x] done").map(\.kind).contains(.checkbox(true)))
        XCTAssertTrue(MarkdownStyler.spans(in: "- [ ] todo").map(\.kind).contains(.checkbox(false)))
    }
}
