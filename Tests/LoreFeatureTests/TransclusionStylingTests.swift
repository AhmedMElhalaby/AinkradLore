import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// The reservation half of M7: what `TransclusionStyling.prepare` does to the
/// storage, and what it refuses to do.
@MainActor
final class TransclusionStylingTests: XCTestCase {

    private var vault: URL!
    private var target: URL!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("m7-styling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        target = vault.appendingPathComponent("target.md")
        try String(repeating: "A paragraph of transcluded prose.\n\n", count: 12)
            .write(to: target, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private func storage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text)
    }

    private func spans(_ text: String) -> [StyleSpan] {
        MarkdownDocumentModel(body: text).styleSpans
    }

    private func prepare(_ text: String, selection: NSRange = NSRange(location: 0, length: 0),
                         width: CGFloat = 600,
                         in store: NSTextStorage) -> [MarkdownBlockBackgrounds.Region] {
        TransclusionStyling.prepare(
            spans(text), selection: selection, width: width,
            theme: MarkdownTheme(tokens: TestTokens.make()),
            resolve: { raw in
                LinkResolver.basename(of: raw) == "target" ? self.target : nil
            },
            cache: TransclusionCache(), in: store)
    }

    /// The whole point: the gap the note is drawn into is the height the note
    /// was measured at, and the two come out of the same call.
    func test_reservesTheMeasuredHeightOfTheTarget() {
        let text = "# Host\n\n![[target]]\n"
        let store = storage(text)
        let regions = prepare(text, in: store)

        XCTAssertEqual(regions.count, 1)
        guard case .transclusion(let box) = regions[0].kind else {
            return XCTFail("expected a transclusion region")
        }
        let expected = TransclusionLayout.height(
            for: TransclusionResolver.resolve(
                rawTarget: "target",
                resolver: LinkResolver(documents: [(url: target, title: "target", aliases: [])]),
                path: []) { try String(contentsOf: $0, encoding: .utf8) },
            width: 600, theme: MarkdownTheme(tokens: TestTokens.make()))
        XCTAssertEqual(box.height, expected, accuracy: 0.5)

        let style = store.attribute(.paragraphStyle,
                                    at: (text as NSString).range(of: "![[target]]").location,
                                    effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.minimumLineHeight ?? 0, box.height, accuracy: 0.5,
                       "the reserved line height must be the measured height")
        XCTAssertEqual(style?.maximumLineHeight ?? 0, box.height, accuracy: 0.5)
    }

    /// Reserving zero and filling it later is what makes an embed pop, so a
    /// width the container has not sized yet reserves ONE LINE instead.
    func test_unmeasurableWidthReservesOneLineNotZero() {
        let text = "![[target]]\n"
        let store = storage(text)
        let regions = prepare(text, width: 0, in: store)

        guard case .transclusion(let box) = regions.first?.kind else {
            return XCTFail("expected a transclusion region")
        }
        let line = TransclusionStyling.placeholderHeight(font: MarkdownStyleRenderer.baseFont)
        XCTAssertEqual(box.height, line, accuracy: 0.01)
        XCTAssertGreaterThan(box.height, 0)
    }

    /// The caret inside the embed means the writer is editing the target, so
    /// the raw source stays visible and nothing is reserved or drawn.
    func test_revealedEmbedIsNotCollapsedOrReserved() {
        let text = "# Host\n\n![[target]]\n"
        let source = (text as NSString).range(of: "![[target]]")
        let store = storage(text)
        let regions = prepare(text,
                              selection: NSRange(location: source.location + 4, length: 0),
                              in: store)

        XCTAssertTrue(regions.isEmpty, "a revealed embed produces no drawing region")
        // `collapse` marks hidden text with a 0.01 pt font; an untouched
        // storage keeps its own default size, which is what "still visible"
        // looks like from here.
        let font = store.attribute(.font, at: source.location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(font?.pointSize ?? 12, 1,
                             "a revealed embed's source must not be collapsed")
    }

    /// The rule the whole editor is built on: decoration never rewrites bytes.
    func test_prepareNeverChangesTheDocumentText() {
        let text = "# Host\n\n![[target]]\n\nAfter.\n"
        let store = storage(text)
        _ = prepare(text, in: store)
        XCTAssertEqual(store.string, text)
    }

    /// A second pass over the same target costs no measurement — the property
    /// the typing gate depends on, asserted here at the unit level too.
    func test_secondPassOverTheSameTargetDoesNotRemeasure() {
        let text = "![[target]]\n"
        let cache = TransclusionCache()
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let resolve: (String) -> URL? = { _ in self.target }

        let first = storage(text)
        TransclusionMeasureCounter.reset()
        _ = TransclusionStyling.prepare(spans(text), selection: NSRange(location: 99, length: 0),
                                        width: 600, theme: theme, resolve: resolve,
                                        cache: cache, in: first)
        let afterFirst = TransclusionMeasureCounter.count
        XCTAssertEqual(afterFirst, 1)

        let second = storage(text)
        _ = TransclusionStyling.prepare(spans(text), selection: NSRange(location: 99, length: 0),
                                        width: 600, theme: theme, resolve: resolve,
                                        cache: cache, in: second)
        XCTAssertEqual(TransclusionMeasureCounter.count, afterFirst)
    }
}
