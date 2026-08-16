import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// `$…$` math.
///
/// Two halves, and the second matters more. The first is that `$x^2$` renders.
/// The second is that the enormous number of dollar signs in ordinary prose —
/// prices, shell variables, currency — do NOT, because a false positive here
/// does not merely fail to render: it tints and collapses a stretch of someone's
/// writing.
final class MarkdownMathTests: XCTestCase {

    private func spans(_ body: String) -> [MarkdownMath.Span] {
        MarkdownMath.spans(in: body as NSString)
    }

    private func styleSpans(_ body: String) -> [StyleSpan] {
        MarkdownDocumentModel(body: body).styleSpans
    }

    // MARK: - Not mathematics

    /// The case that would be worst to get wrong, because it is so common.
    func test_pricesInProseAreNotMath() {
        XCTAssertTrue(spans("it costs $5 and $7 in total\n").isEmpty,
                      "a closing delimiter preceded by a space is not a delimiter")
        XCTAssertTrue(spans("between $10 and $20 per unit\n").isEmpty)
    }

    /// An inline expression may not cross a line. A stray `$` would otherwise
    /// reach for one paragraphs away and tint everything between.
    func test_anInlineExpressionDoesNotCrossALine() {
        XCTAssertTrue(spans("a stray $ here\nand another $ there\n").isEmpty)
    }

    func test_anEmptyExpressionIsNotMath() {
        XCTAssertTrue(spans("$$\n").isEmpty)
        XCTAssertTrue(spans("nothing $$ here\n").isEmpty)
    }

    /// A `$` in a code fence is a shell variable. Without suppression `$PATH`
    /// opens an expression that runs to the next `$` anywhere in the file.
    func test_dollarsInsideCodeAreSuppressed() {
        let body = "```bash\necho $PATH and $HOME\n```\n"
        XCTAssertFalse(styleSpans(body).contains {
            if case .math = $0.kind { return true }
            return false
        }, "a shell variable must not be read as mathematics")
    }

    // MARK: - Mathematics, rendered

    func test_aSimpleSuperscriptRenders() throws {
        let found = spans("area is $x^2$ exactly\n")
        XCTAssertEqual(found.count, 1)
        let math = try XCTUnwrap(found.first)
        XCTAssertTrue(math.isRenderable)
        XCTAssertEqual(math.scripts.count, 1)
        XCTAssertTrue(math.scripts[0].isSuperscript)
        // `$`, `$` and `^` collapse; the `2` is raised.
        XCTAssertEqual(math.markers.count, 1, "the ^ itself")
    }

    func test_aBracedScriptRenders() throws {
        let math = try XCTUnwrap(spans("$x^{10}$\n").first)
        XCTAssertTrue(math.isRenderable)
        XCTAssertEqual(math.scripts.count, 1)
        // The `^` and both braces collapse.
        XCTAssertEqual(math.markers.count, 3)
    }

    func test_subscriptsRenderToo() throws {
        let math = try XCTUnwrap(spans("$a_i$\n").first)
        XCTAssertTrue(math.isRenderable)
        XCTAssertEqual(math.scripts.first?.isSuperscript, false)
    }

    func test_theSpansReachTheStyleLayer() {
        let found = styleSpans("area is $x^2$ exactly\n")
        XCTAssertTrue(found.contains { $0.kind == .math(isRendered: true) })
        XCTAssertTrue(found.contains { $0.kind == .mathScript(isSuperscript: true) })
        XCTAssertTrue(found.contains { $0.kind == .marker(of: .math) })
    }

    // MARK: - Mathematics this editor cannot draw

    /// The all-or-nothing rule. A `\\frac` cannot be rendered without inserting
    /// characters, so the WHOLE expression stays as source — delimiters and all
    /// — rather than being half-rendered.
    func test_anExpressionWithACommandIsLeftAsSource() throws {
        let math = try XCTUnwrap(spans("$\\frac{a}{b}$\n").first)
        XCTAssertFalse(math.isRenderable)
        XCTAssertTrue(math.markers.isEmpty, "nothing may collapse")
        XCTAssertTrue(math.scripts.isEmpty)
    }

    /// And its `$` delimiters must stay VISIBLE — collapsing them would leave
    /// `\\frac{a}{b}` looking like prose someone typed by accident.
    func test_anUnrenderableExpressionKeepsItsDelimiters() {
        let body = "$\\frac{a}{b}$\n"
        let hidden = MarkdownReveal.hiddenMarkers(
            spans: styleSpans(body), selection: NSRange(location: 0, length: 0),
            text: body, isFocused: false)
        XCTAssertTrue(hidden.isEmpty, "nothing in an unrenderable expression collapses")
    }

    /// It is still TINTED, so the reader can see it is mathematics rather than
    /// a typo — the whole value of recognising it at all.
    func test_anUnrenderableExpressionIsStillMarkedAsMath() {
        XCTAssertTrue(styleSpans("$\\frac{a}{b}$\n")
            .contains { $0.kind == .math(isRendered: false) })
    }

    /// An expression with nothing to render — no scripts — keeps its
    /// delimiters too, or the text would silently stop looking like maths.
    func test_anExpressionWithNothingToRenderKeepsItsDelimiters() throws {
        let math = try XCTUnwrap(spans("$a + b$\n").first)
        XCTAssertFalse(math.isRenderable)
    }

    // MARK: - On screen

    /// A superscript must actually be SMALLER and RAISED. Asserted on the
    /// attributes the reader sees, not on the span that requested them.
    @MainActor
    func test_aSuperscriptIsSmallerAndRaised() throws {
        let body = "area is $x^2$ exactly\n"
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = body
        coordinator.textView = tv
        coordinator.applyStyles()

        try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            let ns = body as NSString
            let exponent = ns.range(of: "2")
            let prose = ns.range(of: "area")

            let small = try XCTUnwrap(storage.attribute(.font, at: exponent.location,
                                                        effectiveRange: nil) as? NSFont)
            let normal = try XCTUnwrap(storage.attribute(.font, at: prose.location,
                                                         effectiveRange: nil) as? NSFont)
            XCTAssertLessThan(small.pointSize, normal.pointSize,
                              "an exponent must be smaller than body text")
            let offset = storage.attribute(.baselineOffset, at: exponent.location,
                                           effectiveRange: nil) as? CGFloat
            XCTAssertGreaterThan(offset ?? 0, 0, "and raised above the baseline")
        }
    }
}
