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

extension MarkdownThemeTests {
    private func style(_ block: MarkdownBlock) -> NSParagraphStyle {
        MarkdownParagraphStyles.style(for: block, theme: MarkdownTheme(tokens: TestTokens.make()))
    }

    /// `headIndent` is what makes a WRAPPED list line align under the text
    /// instead of under the bullet. Without it a two-line bullet looks broken,
    /// which is most of "lists are unstyled".
    func test_listItemHangsWrappedLinesUnderTheText() {
        let s = style(.listItem(depth: 0))
        XCTAssertGreaterThan(s.headIndent, s.firstLineHeadIndent,
                             "wrapped lines must be indented past the bullet")
    }

    func test_nestedListsStepByDepth() {
        let d0 = style(.listItem(depth: 0)).firstLineHeadIndent
        let d1 = style(.listItem(depth: 1)).firstLineHeadIndent
        let d2 = style(.listItem(depth: 2)).firstLineHeadIndent
        XCTAssertEqual(d1 - d0, d2 - d1, accuracy: 0.01, "depth must step uniformly")
        XCTAssertGreaterThan(d1, d0)
    }

    func test_blockQuoteIsIndentedToLeaveRoomForItsBar() {
        XCTAssertGreaterThan(style(.blockQuote).firstLineHeadIndent, 0)
    }

    /// Indentation is a paragraph attribute, never inserted characters —
    /// inserting whitespace would change the document, and every index and
    /// link offset with it.
    func test_headingsCarryTheirOwnSpacing() {
        let h1 = style(.heading(1))
        XCTAssertGreaterThan(h1.paragraphSpacingBefore, 0)
        XCTAssertGreaterThan(h1.paragraphSpacing, 0)
    }
}
