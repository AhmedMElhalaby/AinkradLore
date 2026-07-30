import SwiftUI
import AinkradAppKit

/// Every size and every gap in the markdown editor, in one value.
///
/// M2a had these numbers inline at their use sites, which is how the editor
/// ended up with no vertical rhythm at all: there was no single place where
/// "how far apart are two paragraphs" was a question anyone had to answer.
/// M3 (PDF) and M4 (rich text) render the same documents, so this value is the
/// seam that stops the three from drifting apart.
///
/// Colour still comes from `HostThemeTokens` — the theme owns hue, this owns
/// scale.
struct MarkdownTheme: Equatable {
    let bodySize: CGFloat
    let lineHeightMultiple: CGFloat
    let paragraphSpacing: CGFloat
    let listIndentStep: CGFloat
    let contentInset: CGFloat
    /// Nil means "fill the width". A measure much beyond ~70 characters is
    /// tiring to read, which is what an unbounded editor gives you on a wide
    /// window.
    let maxMeasure: CGFloat?

    init(tokens: HostThemeTokens) {
        bodySize = 15
        lineHeightMultiple = 1.5
        paragraphSpacing = 12
        listIndentStep = 22
        contentInset = 28
        maxMeasure = 760
    }

    /// h1…h6. Clamped so an out-of-range level from a malformed document
    /// cannot produce a negative or absurd size.
    func headingSize(_ level: Int) -> CGFloat {
        let steps: [CGFloat] = [30, 24, 20, 17.5, 16, 15.5]
        return steps[min(max(level, 1), 6) - 1]
    }

    func headingSpacingBefore(_ level: Int) -> CGFloat {
        max(10, headingSize(level) * 0.9)
    }

    func headingSpacingAfter(_ level: Int) -> CGFloat {
        max(4, headingSize(level) * 0.25)
    }
}
