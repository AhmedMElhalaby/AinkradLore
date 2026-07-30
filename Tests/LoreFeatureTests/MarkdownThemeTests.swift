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

    /// Requirement 2. The owner's complaint was that text runs edge to edge.
    /// `contentInset` existed and was ignored in favour of a hard-coded 16.
    func test_theTextContainerUsesTheThemeInsetRatherThanAHardcodedSixteen() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        // Narrow enough that the measure cap cannot be the thing setting the
        // inset — this is the plain "comfortable margin" case.
        let inset = MarkdownEditorLayout.containerInset(forViewWidth: 500, theme: theme)
        XCTAssertEqual(inset.width, theme.contentInset, accuracy: 0.01)
        XCTAssertNotEqual(inset.width, 16, accuracy: 0.01)
    }

    /// Requirement 2. On a wide window the column is capped at `maxMeasure`
    /// and CENTRED — equal margins, not a left-hugging column.
    func test_aWideViewCapsAndCentresTheTextColumnAtMaxMeasure() throws {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let measure = try XCTUnwrap(theme.maxMeasure)
        let width: CGFloat = 2000
        let inset = MarkdownEditorLayout.containerInset(forViewWidth: width, theme: theme)
        XCTAssertEqual(width - inset.width * 2, measure, accuracy: 0.5,
                       "the column must be capped at the theme's measure")
        XCTAssertGreaterThan(inset.width, theme.contentInset,
                             "a wide view must grow its margins, not its column")
        // Centred: one symmetric inset means left margin == right margin.
        XCTAssertEqual(inset.width, width - (inset.width + measure), accuracy: 0.5)
    }

    /// The cap must never make the margin smaller than the theme's floor on a
    /// narrow window — a phone-width pane still gets its breathing room.
    func test_aNarrowViewNeverShrinksBelowTheThemeInset() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let inset = MarkdownEditorLayout.containerInset(forViewWidth: 120, theme: theme)
        XCTAssertEqual(inset.width, theme.contentInset, accuracy: 0.01)
    }

    /// Requirement 3. Once the column is centred, the drawn decoration has to
    /// move with it. Two coordinate sources (`textContainerOrigin` for the
    /// text rect, `textContainerInset` for the panel x) agree only while the
    /// column is NOT centred, so this is the test that pins them together.
    func test_backgroundGeometryTracksTheTextColumnWhenCentred() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let width: CGFloat = 2000
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = MarkdownEditorLayout.containerInset(forViewWidth: width,
                                                                    theme: theme)
        let x = MarkdownBlockBackgrounds.columnX(in: tv)
        let columnWidth = MarkdownBlockBackgrounds.columnWidth(in: tv)
        XCTAssertEqual(x, tv.textContainerOrigin.x, accuracy: 0.5,
                       "decoration must use the same origin the text rects use")
        XCTAssertGreaterThan(x, theme.contentInset,
                             "a centred column starts well right of the bare inset")
        XCTAssertEqual(width - (x + columnWidth), x, accuracy: 2,
                       "the panel must be as far from the right edge as from the left")
    }

    /// Requirement 6. `MarkdownParagraphStyles` has taken a depth since Task 5;
    /// nothing ever supplied one, so every nesting level rendered flat.
    func test_nestedListItemsIndentByDerivedDepth() throws {
        let tokens = TestTokens.make()
        let body = "- outer\n    - inner\n"
        let model = MarkdownDocumentModel(body: body)
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.apply(model.styleSpans, to: storage, tokens: tokens,
                                    theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let outer = try XCTUnwrap(storage.attribute(
            .paragraphStyle, at: (body as NSString).range(of: "outer").location,
            effectiveRange: nil) as? NSParagraphStyle)
        let inner = try XCTUnwrap(storage.attribute(
            .paragraphStyle, at: (body as NSString).range(of: "inner").location,
            effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(outer.firstLineHeadIndent, 0,
                             "even a top-level item must indent")
        XCTAssertGreaterThan(inner.firstLineHeadIndent, outer.firstLineHeadIndent,
                             "a nested item must indent past its parent")
    }

    /// Depth is DERIVED from containment, so a second top-level item after a
    /// nested one must fall back to depth 0 rather than inheriting the nesting.
    func test_listDepthReturnsToZeroAfterANestedItem() {
        let spans = [StyleSpan(range: 0..<20, kind: .listItem),
                     StyleSpan(range: 5..<15, kind: .listItem),
                     StyleSpan(range: 20..<30, kind: .listItem)]
        XCTAssertEqual(MarkdownListDepth.depths(of: spans), [0, 1, 0])
    }

    /// Requirement 4. Regions are derived from ALL spans while attributes are
    /// windowed, so an unclipped panel could be painted behind text that was
    /// never styled.
    func test_regionsAreClippedToTheViewportWindow() {
        let spans = [StyleSpan(range: 0..<10, kind: .codeBlock(language: nil)),
                     StyleSpan(range: 100..<120, kind: .blockQuote)]
        let window = NSRange(location: 0, length: 50)
        let regions = MarkdownBlockBackgrounds.regions(for: spans, length: 200,
                                                       limitedTo: window)
        XCTAssertEqual(regions, [
            .init(kind: .codePanel, range: NSRange(location: 0, length: 10))
        ], "a region outside the styled window must not be drawn")
    }

    /// A region straddling the window edge is clipped, not dropped — the
    /// visible half still needs its panel.
    func test_aRegionStraddlingTheWindowIsClippedNotDropped() {
        let spans = [StyleSpan(range: 40..<200, kind: .codeBlock(language: nil))]
        let regions = MarkdownBlockBackgrounds.regions(
            for: spans, length: 200, limitedTo: NSRange(location: 0, length: 50))
        XCTAssertEqual(regions, [
            .init(kind: .codePanel, range: NSRange(location: 40, length: 10))
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
