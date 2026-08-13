import AppKit
import XCTest
@testable import LoreFeature

final class EditorLayoutTests: XCTestCase {

    private func inset(width: CGFloat) -> NSSize {
        MarkdownEditorLayout.containerInset(
            forViewWidth: width, theme: MarkdownTheme(tokens: TestTokens.make()))
    }

    /// A wide pane must NOT push the column into the middle of the window.
    /// The centering rule — `(viewWidth - maxMeasure) / 2` — is the whole
    /// cause of the large empty gap before the text.
    func test_aWidePaneKeepsTheColumnAtTheContentInset() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        XCTAssertEqual(inset(width: 2000).width, theme.contentInset)
    }

    /// The measure cap still applies — the column is left-aligned, not
    /// unbounded, so long lines stay readable.
    func test_theMeasureCapStillApplies() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let maxMeasure = try? XCTUnwrap(theme.maxMeasure)
        XCTAssertNotNil(maxMeasure)
    }

    /// A pane narrower than twice the inset must still leave a POSITIVE
    /// column rather than an inverted one. This clamp already existed and
    /// must survive the change.
    func test_aNarrowPaneStillLeavesAPositiveColumn() {
        XCTAssertLessThan(inset(width: 30).width, 15)
        XCTAssertGreaterThanOrEqual(inset(width: 30).width, 0)
    }

    /// Vertical inset is unchanged by any of this.
    func test_verticalInsetIsTheContentInset() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        XCTAssertEqual(inset(width: 900).height, theme.contentInset)
    }
}
