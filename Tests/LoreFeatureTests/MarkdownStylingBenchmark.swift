import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// Measurements, not correctness assertions — the M2a claim that AST styling is
/// affordable is a number here rather than a sentence in a report.
final class MarkdownStylingBenchmark: XCTestCase {

    /// The property that matters: parse count is bounded by the DEBOUNCE, not
    /// by the number of characters typed. Before M2a the styler ran a full
    /// regex sweep per keystroke; an AST parse per keystroke would be worse.
    ///
    /// MEASURED, Debug (unoptimised), 2026-07-30: 3.75 s average for ~230 KB.
    /// Split by hand at the time: 0.35 s for the AST walk, 3.20 s for
    /// `wikilinkSpans` — i.e. 85% of the cost is the on-demand link scan, not
    /// swift-markdown. That is why the editor parses once per debounce and
    /// never on a keystroke, and it is the number Task 7+ should attack.
    func test_parsingALargeDocumentIsFastEnoughToDebounce() {
        let paragraph = "Some **bold** text with a [[Link]] and `code`.\n\n"
        let body = String(repeating: paragraph, count: 5_000)   // ~230 KB
        XCTAssertGreaterThan((body as NSString).length, 200_000)

        measure {
            _ = MarkdownDocumentModel(fullText: body).styleSpans
        }
    }

    func test_aDocumentOverTheHardCapProducesNoSpans() {
        let body = String(repeating: "x", count: MarkdownDocumentModel.stylingHardCap + 1)
        XCTAssertTrue(MarkdownDocumentModel(fullText: body).styleSpans.isEmpty)
    }

    func test_aDocumentUnderTheHardCapStillProducesSpans() {
        XCTAssertFalse(MarkdownDocumentModel(fullText: "# Heading\n").styleSpans.isEmpty)
    }

    func test_capsAreOrdered() {
        XCTAssertLessThan(MarkdownDocumentModel.stylingViewportCap,
                          MarkdownDocumentModel.stylingHardCap)
    }
}

/// The mandatory half of Task 6: keystrokes must not parse.
@MainActor
final class MarkdownStylingCacheTests: XCTestCase {

    private func makeEditor(_ text: String)
        -> (MarkdownEditor.Coordinator, NSTextView, Binding<String>) {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = text
        coordinator.textView = tv
        coordinator.applyStyles()
        return (coordinator, tv, binding)
    }

    /// A keystroke re-renders from the cache and arms the debounce; it does not
    /// parse. This is the regression the whole task exists to prevent.
    func test_keystrokesDoNotParse() {
        let (coordinator, tv, _) = makeEditor("# Title\n\nSome **bold** here.\n")
        withExtendedLifetime(coordinator) {
            MarkdownParseCounter.reset()
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            for character in "hello world" {
                tv.insertText(String(character), replacementRange: tv.selectedRange())
            }
            XCTAssertEqual(MarkdownParseCounter.count, 0,
                           "11 keystrokes must cost zero markdown parses")
        }
    }

    /// An ancestor redraw — theme change, banner, window resize — re-renders
    /// from the cache too. This path used to cost two parses per redraw.
    func test_reRenderingUnchangedTextDoesNotParse() {
        let (coordinator, _, _) = makeEditor("# Title\n\n- [ ] task\n")
        withExtendedLifetime(coordinator) {
            MarkdownParseCounter.reset()
            for _ in 0..<10 { coordinator.applyStyles() }
            XCTAssertEqual(MarkdownParseCounter.count, 0)
        }
    }

    /// Text arriving from outside the editor (document switch, external write)
    /// is not a keystroke and has no cached spans to shift, so it parses once,
    /// synchronously — styling a freshly opened note must not lag.
    func test_externallyReplacedTextParsesOnce() {
        let (coordinator, tv, _) = makeEditor("start")
        withExtendedLifetime(coordinator) {
            MarkdownParseCounter.reset()
            tv.string = "# Replaced\n"
            coordinator.applyStyles()
            coordinator.applyStyles()
            XCTAssertEqual(MarkdownParseCounter.count, 1)
        }
    }

    /// The debounce eventually fires and refreshes the cache with real spans.
    func test_theDebouncedParseEventuallyRuns() {
        let (coordinator, tv, _) = makeEditor("plain text\n")
        withExtendedLifetime(coordinator) {
            MarkdownParseCounter.reset()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            for character in "# " { tv.insertText(String(character), replacementRange: tv.selectedRange()) }
            XCTAssertEqual(MarkdownParseCounter.count, 0)

            let parsed = expectation(description: "debounced parse")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { parsed.fulfill() }
            wait(for: [parsed], timeout: 2)

            XCTAssertEqual(MarkdownParseCounter.count, 1,
                           "one parse for the whole burst, not one per keystroke")
            XCTAssertTrue(coordinator.cachedSpansForTesting.contains { $0.kind == .heading(1) })
        }
    }

    /// Above the hard cap the editor must not parse AT ALL. Serving `[]` from a
    /// full parse would make "styling off" the most expensive path there is —
    /// the exact opposite of what the cap exists for.
    func test_aDocumentOverTheHardCapIsNeverParsed() {
        let huge = String(repeating: "x", count: MarkdownDocumentModel.stylingHardCap + 1)
        var cache = MarkdownStyleCache()
        MarkdownParseCounter.reset()
        cache.reparse(huge)
        XCTAssertEqual(MarkdownParseCounter.count, 0,
                       "an over-cap document must cost zero parses")
        XCTAssertTrue(cache.spans.isEmpty)
        XCTAssertTrue(cache.isOverHardCap, "the editor must still say styling is off")
        XCTAssertTrue(cache.describes(huge),
                      "the cache must claim currency, or every redraw re-enters this path")
    }

    /// The guard must not swallow ordinary documents.
    func test_aDocumentUnderTheHardCapIsStillParsed() {
        var cache = MarkdownStyleCache()
        MarkdownParseCounter.reset()
        cache.reparse("# Heading\n\n**bold**\n")
        XCTAssertEqual(MarkdownParseCounter.count, 1)
        XCTAssertFalse(cache.isOverHardCap)
        XCTAssertTrue(cache.spans.contains { $0.kind == .strong })
    }

    // MARK: - Span shifting

    func test_spansAfterTheEditShiftByTheDelta() {
        var cache = MarkdownStyleCache()
        cache.reparse("# A\n\n**b**\n")
        let before = cache.spans.first { $0.kind == .strong }!.range
        // An insertion in the blank line, entirely before the strong span.
        cache.shift(editedRange: NSRange(location: 4, length: 0), delta: 3,
                    newText: "# A\nxxx\n**b**\n")
        let after = cache.spans.first { $0.kind == .strong }!.range
        XCTAssertEqual(after.lowerBound, before.lowerBound + 3)
        XCTAssertEqual(after.upperBound, before.upperBound + 3)
    }

    func test_spansBeforeTheEditAreUntouched() {
        var cache = MarkdownStyleCache()
        cache.reparse("**b** tail\n")
        let strongBefore = cache.spans.first { $0.kind == .strong }?.range
        cache.shift(editedRange: NSRange(location: 10, length: 0), delta: 1,
                    newText: "**b** tail!\n")
        XCTAssertEqual(cache.spans.first { $0.kind == .strong }?.range, strongBefore)
    }

    /// Typing INSIDE a span grows it, so bold text does not visibly stop being
    /// bold for the length of the debounce.
    func test_anEditInsideASpanGrowsIt() {
        var cache = MarkdownStyleCache()
        cache.reparse("**bd**\n")
        let before = cache.spans.first { $0.kind == .strong }!.range
        cache.shift(editedRange: NSRange(location: 3, length: 0), delta: 1,
                    newText: "**bod**\n")
        let after = cache.spans.first { $0.kind == .strong }!.range
        XCTAssertEqual(after.lowerBound, before.lowerBound)
        XCTAssertEqual(after.upperBound, before.upperBound + 1)
    }

    /// A deletion must never invert a range — an inverted `Range<Int>` traps.
    func test_aDeletionSpanningASpanDoesNotInvertIt() {
        var cache = MarkdownStyleCache()
        cache.reparse("**bold**\n")
        cache.shift(editedRange: NSRange(location: 0, length: 8), delta: -8, newText: "\n")
        for span in cache.spans {
            XCTAssertLessThanOrEqual(span.range.lowerBound, span.range.upperBound)
            XCTAssertLessThanOrEqual(span.range.upperBound, 1)
        }
    }
}
