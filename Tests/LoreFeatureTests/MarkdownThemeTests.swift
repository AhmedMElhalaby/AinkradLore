import XCTest
import AppKit
import SwiftUI
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

/// Task 6: accent stops meaning "important" and starts meaning "clickable".
@MainActor
extension MarkdownThemeTests {

    /// Headings use FOREGROUND. Accent is reserved for things you can click,
    /// so accent means "interactive" rather than "important".
    func test_headingsUseForegroundNotAccent() {
        let tokens = TestTokens.make()
        let storage = NSTextStorage(string: "# Title")
        MarkdownStyleRenderer.apply(
            [StyleSpan(range: 0..<7, kind: .heading(1))],
            to: storage, tokens: tokens,
            theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let colour = storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour, NSColor(tokens.foreground))
    }

    /// Code loses the accent tint entirely — mono plus a background is enough,
    /// and the tint is what made whole fences read as coloured bands.
    func test_codeIsNotTintedWithAccent() {
        let tokens = TestTokens.make()
        let storage = NSTextStorage(string: "let x = 1")
        MarkdownStyleRenderer.apply(
            [StyleSpan(range: 0..<9, kind: .codeBlock(language: "swift"))],
            to: storage, tokens: tokens,
            theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let colour = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(colour, NSColor(tokens.accentSecondary))
    }

    /// Links keep accent — that is now what accent MEANS.
    func test_linksKeepAccent() {
        let tokens = TestTokens.make()
        let storage = NSTextStorage(string: "[[Target]]")
        MarkdownStyleRenderer.apply(
            [StyleSpan(range: 0..<10, kind: .wikilink)],
            to: storage, tokens: tokens,
            theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let colour = storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour, NSColor(tokens.accentPrimary))
    }

    func test_headingSizesComeFromTheTheme() {
        let tokens = TestTokens.make()
        let theme = MarkdownTheme(tokens: tokens)
        let storage = NSTextStorage(string: "# T")
        MarkdownStyleRenderer.apply([StyleSpan(range: 0..<3, kind: .heading(1))],
                                    to: storage, tokens: tokens,
                                    theme: theme, limitedTo: nil)
        let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(try XCTUnwrap(font).pointSize, theme.headingSize(1), accuracy: 0.01)
    }

    /// A whole fence must NOT carry a per-glyph background: that attribute
    /// stops at the end of each line, which is the ragged staircase this task
    /// replaced with a drawn panel.
    func test_codeBlocksCarryNoPerGlyphBackground() {
        let tokens = TestTokens.make()
        let storage = NSTextStorage(string: "let x = 1\nlet yy = 22")
        MarkdownStyleRenderer.apply(
            [StyleSpan(range: 0..<21, kind: .codeBlock(language: nil))],
            to: storage, tokens: tokens,
            theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        XCTAssertNil(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil),
                     "code panels are drawn, not attributed")
    }

    /// The drawn regions are derived from the block spans, and only those.
    func test_regionsCoverCodeAndQuotesOnly() {
        let spans = [StyleSpan(range: 0..<5, kind: .codeBlock(language: nil)),
                     StyleSpan(range: 5..<9, kind: .blockQuote),
                     StyleSpan(range: 9..<12, kind: .heading(2)),
                     StyleSpan(range: 12..<40, kind: .blockQuote)]   // past the end
        let regions = MarkdownBlockBackgrounds.regions(for: spans, length: 12)
        XCTAssertEqual(regions, [
            .init(kind: .codePanel, range: NSRange(location: 0, length: 5)),
            .init(kind: .quoteBar, range: NSRange(location: 5, length: 4))
        ])
    }

    /// Body text gets real line height even with no spans at all — the rhythm
    /// is the floor, not something only headings enjoy.
    func test_bodyTextCarriesTheThemesLineHeight() {
        let tokens = TestTokens.make()
        let theme = MarkdownTheme(tokens: tokens)
        let storage = NSTextStorage(string: "just prose")
        MarkdownStyleRenderer.apply([], to: storage, tokens: tokens,
                                    theme: theme, limitedTo: nil)
        let style = storage.attribute(.paragraphStyle, at: 0,
                                      effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(try XCTUnwrap(style).lineHeightMultiple,
                       theme.lineHeightMultiple, accuracy: 0.01)
    }
}
