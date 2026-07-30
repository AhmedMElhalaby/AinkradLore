import XCTest
@testable import LoreFeature

final class MarkdownThemeTests: XCTestCase {
    private var theme: MarkdownTheme { MarkdownTheme(tokens: TestTokens.make()) }

    /// Hierarchy must come from SIZE, monotonically. M2a used colour for this,
    /// which is what made a note read as bands of accent rather than as text.
    func test_headingSizesDescendStrictlyAndStayAboveBody() {
        let sizes = (1...6).map { theme.headingSize($0) }
        for (a, b) in zip(sizes, sizes.dropFirst()) {
            XCTAssertGreaterThan(a, b, "each heading level must be smaller than the one above")
        }
        XCTAssertGreaterThan(try XCTUnwrap(sizes.last), theme.bodySize,
                             "even h6 must outrank body text")
    }

    /// Rhythm: space before a heading exceeds space after it, so a heading
    /// binds to the text it introduces rather than floating between blocks.
    func test_headingBindsToTheTextBelowIt() {
        for level in 1...6 {
            XCTAssertGreaterThan(theme.headingSpacingBefore(level),
                                 theme.headingSpacingAfter(level),
                                 "h\(level) must sit closer to what follows it")
        }
    }

    func test_bodyHasRealLineHeightAndParagraphSpacing() {
        XCTAssertGreaterThan(theme.lineHeightMultiple, 1.0)
        XCTAssertGreaterThan(theme.paragraphSpacing, 0)
        XCTAssertGreaterThan(theme.contentInset, 0, "text must not run edge to edge")
    }
}
