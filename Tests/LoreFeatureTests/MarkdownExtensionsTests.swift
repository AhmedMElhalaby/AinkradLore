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
}
