import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// GFM pipe tables.
///
/// The parse is pure and asserted directly. The ALIGNMENT is asserted where it
/// actually matters — on screen, by asking the text view where each column
/// starts — because "the kern attribute was written" is a fact about an
/// attribute, and what was asked for is columns that line up.
final class MarkdownTableTests: XCTestCase {

    private func parse(_ body: String) -> MarkdownTable? {
        let ns = body as NSString
        return MarkdownTable.parse(range: 0..<ns.length, in: ns)
    }

    // MARK: - Parsing

    func test_rowsCellsAndWidthsAreRead() throws {
        let body = "| name | qty |\n|---|---|\n| apple | 3 |\n"
        let table = try XCTUnwrap(parse(body))
        XCTAssertEqual(table.rows.count, 2, "header and one body row; the delimiter is not a row")
        XCTAssertNotNil(table.delimiterRow)
        XCTAssertEqual(table.rows.map { $0.cells.count }, [2, 2])
        // Widths are the WIDEST cell per column: "apple" (5) beats "name" (4).
        XCTAssertEqual(table.columnWidths, [5, 3])
    }

    func test_cellContentIsTrimmedOfItsPadding() throws {
        let body = "|  a  |   b |\n|---|---|\n| c | d |\n"
        let table = try XCTUnwrap(parse(body))
        let ns = body as NSString
        let first = try XCTUnwrap(table.rows.first?.cells.first)
        XCTAssertEqual(ns.substring(with: NSRange(location: first.range.lowerBound,
                                                  length: first.range.count)), "a")
        XCTAssertEqual(first.width, 1)
    }

    /// Both spellings are legal GFM and a vault contains both.
    func test_aTableWithoutOuterPipesParses() throws {
        let table = try XCTUnwrap(parse("a | b\n--|--\nc | d\n"))
        XCTAssertEqual(table.rows.map { $0.cells.count }, [2, 2])
        XCTAssertEqual(table.columnWidths, [1, 1])
    }

    /// `\|` is how GFM writes a literal pipe. Splitting on it would shear the
    /// row into the wrong number of columns and misalign every one after it.
    func test_anEscapedPipeIsContentNotASeparator() throws {
        let table = try XCTUnwrap(parse("| a \\| b | c |\n|---|---|\n| d | e |\n"))
        XCTAssertEqual(table.rows.first?.cells.count, 2,
                       "`a \\| b` is ONE cell")
    }

    /// The delimiter is the second line by definition. A body cell holding
    /// `---` is content, and hiding that row would delete a row of the table.
    func test_onlyTheSecondLineCanBeTheDelimiter() throws {
        let table = try XCTUnwrap(parse("| a | b |\n|---|---|\n| --- | x |\n"))
        XCTAssertEqual(table.rows.count, 2,
                       "the `| --- |` body row is a ROW, not a second delimiter")
    }

    func test_alignmentColonsAreStillADelimiter() throws {
        XCTAssertNotNil(try XCTUnwrap(parse("| a | b |\n|:--|--:|\n| c | d |\n")).delimiterRow)
    }

    func test_somethingThatIsNotATableIsRejected() {
        XCTAssertNil(parse("just prose\n"))
        XCTAssertNil(parse("| only one line |\n"))
    }

    // MARK: - Spans

    private func spans(_ body: String) -> [StyleSpan] {
        MarkdownDocumentModel(body: body).styleSpans
    }

    func test_aTableEmitsItsSpans() {
        let found = spans("| a | b |\n|---|---|\n| c | d |\n")
        XCTAssertTrue(found.contains { $0.kind == .table }, "the table itself")
        XCTAssertTrue(found.contains { $0.kind == .tableHeader }, "its header row")
        XCTAssertTrue(found.contains { $0.kind == .marker(of: .tableDelimiter) },
                      "the |---| row, as a marker so it collapses whole")
        XCTAssertGreaterThan(found.filter { $0.kind == .marker(of: .tablePipe) }.count, 3,
                             "every | is a marker")
    }

    /// The delimiter row must be HIDDEN when the caret is elsewhere — it is
    /// pure notation, and a rendered table does not show it.
    func test_theDelimiterRowCollapsesWhenTheCaretIsElsewhere() {
        let body = "intro\n\n| a | b |\n|---|---|\n| c | d |\n"
        let hidden = MarkdownReveal.hiddenMarkers(
            spans: spans(body), selection: NSRange(location: 0, length: 0),
            text: body, isFocused: true)
        let delimiter = (body as NSString).range(of: "|---|---|")
        XCTAssertTrue(hidden.contains { $0.lowerBound <= delimiter.location
                                        && $0.upperBound >= NSMaxRange(delimiter) },
                      "the delimiter row must be collapsed")
    }

    // MARK: - Column alignment markers

    func test_delimiterColonsSetTheColumnAlignment() throws {
        let table = try XCTUnwrap(parse("| a | b | c | d |\n|:--|--:|:-:|---|\n| e | f | g | h |\n"))
        XCTAssertEqual(table.columnAlignments, [.left, .right, .center, .left])
    }

    func test_aTableWithNoColonsIsAllLeft() throws {
        let table = try XCTUnwrap(parse("| a | b |\n|---|---|\n| c | d |\n"))
        XCTAssertEqual(table.columnAlignments, [.left, .left])
    }

    /// A RIGHT-aligned column's cells must end at the same x, which is the
    /// whole point of asking for one. Measured on screen, like the alignment
    /// test below and for the same reason.
    @MainActor
    func test_aRightAlignedColumnEndsFlush() throws {
        let body = "intro\n\n| n | qty |\n|---|--:|\n| a | 3 |\n| b | 1200 |\n"
        let (coordinator, tv) = editor(body)
        try withExtendedLifetime(coordinator) {
            let ns = body as NSString
            func end(of cell: String) -> CGFloat {
                let range = ns.range(of: cell)
                XCTAssertNotEqual(range.location, NSNotFound, "fixture must contain \(cell)")
                let rect = tv.firstRect(forCharacterRange: range, actualRange: nil)
                XCTAssertGreaterThan(rect.width, 0, "\(cell) must have been laid out")
                return rect.maxX
            }
            XCTAssertEqual(end(of: "3"), end(of: "1200"), accuracy: 1.0,
                           "a right-aligned column's cells must share a trailing edge")
        }
    }

    /// And a LEFT column in the same table still starts flush, so honouring one
    /// column's colon does not disturb its neighbour.
    @MainActor
    func test_alignmentIsPerColumn() throws {
        let body = "intro\n\n| n | qty |\n|---|--:|\n| a | 3 |\n| bbb | 1200 |\n"
        let (coordinator, tv) = editor(body)
        try withExtendedLifetime(coordinator) {
            let ns = body as NSString
            func start(of cell: String) -> CGFloat {
                let range = ns.range(of: cell)
                XCTAssertNotEqual(range.location, NSNotFound)
                return tv.firstRect(forCharacterRange: range, actualRange: nil).minX
            }
            XCTAssertEqual(start(of: "a |"), start(of: "bbb |"), accuracy: 1.0,
                           "the left column keeps its leading edge")
        }
    }

    // MARK: - Alignment, measured on screen

    /// Windows are retained for the length of the test, and the view is laid
    /// out before anything is measured.
    ///
    /// Both matter, and the first version of the alignment test had neither:
    /// `firstRect(forCharacterRange:)` on a text view with no window returns
    /// zero for EVERY range, so the assertion compared 0 against 0 and passed
    /// whether or not the columns were aligned. Caught by disabling
    /// `MarkdownTableStyling.align` and watching this test go on passing.
    private var windows: [NSWindow] = []

    @MainActor
    private func editor(_ body: String) -> (MarkdownEditor.Coordinator, LinkTextView) {
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        tv.isRichText = false
        tv.delegate = coordinator
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        windows.append(window)
        tv.string = body
        coordinator.textView = tv
        coordinator.applyStyles()
        tv.layoutSubtreeIfNeeded()
        return (coordinator, tv)
    }

    /// THE test. Cells in the same column must START at the same x.
    ///
    /// Asserted through `firstRect(forCharacterRange:)` — where the text view
    /// actually puts the glyphs — rather than by reading back the `.kern`
    /// attribute, which would prove only that a number was written.
    @MainActor
    func test_columnsLineUpOnScreen() throws {
        // Deliberately ragged: every cell in column two is a different width,
        // so unaligned columns cannot pass by coincidence.
        let body = "intro\n\n| name | qty |\n|---|---|\n| apple | 3 |\n| fig | 12 |\n"
        let (coordinator, tv) = editor(body)
        try withExtendedLifetime(coordinator) {
            let ns = body as NSString
            func columnStart(of cell: String) -> CGFloat {
                let range = ns.range(of: cell)
                XCTAssertNotEqual(range.location, NSNotFound, "fixture must contain \(cell)")
                let rect = tv.firstRect(forCharacterRange: range, actualRange: nil)
                // A zero rect means the view never laid out, and every
                // comparison below would then be 0 against 0 — the exact way
                // this test used to pass without measuring anything.
                XCTAssertGreaterThan(rect.width, 0, "\(cell) must have been laid out")
                return rect.minX
            }
            // Column two, across the header and both body rows.
            let qty = columnStart(of: "qty")
            let three = columnStart(of: "3 |")
            let twelve = columnStart(of: "12 |")
            XCTAssertEqual(qty, three, accuracy: 1.0,
                           "the header and the first body row must share a column edge")
            XCTAssertEqual(qty, twelve, accuracy: 1.0,
                           "and so must the second, whose cell is a different width")
        }
    }

    /// The row the caret is ON goes back to source — pipes visible, padding
    /// gone — which is what Obsidian does and what makes the row editable.
    @MainActor
    func test_theCaretsOwnRowDropsItsPadding() throws {
        let body = "intro\n\n| name | qty |\n|---|---|\n| apple | 3 |\n"
        let (coordinator, tv) = editor(body)
        try withExtendedLifetime(coordinator) {
            let ns = body as NSString
            let pipe = ns.range(of: "| qty |")
            // Caret far away: the header's pipes are collapsed AND padded.
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.revealForSelectionChange()
            let padded = try XCTUnwrap(tv.textStorage)
                .attribute(.kern, at: pipe.location, effectiveRange: nil) as? CGFloat

            // Caret into the header row.
            tv.setSelectedRange(NSRange(location: pipe.location + 2, length: 0))
            coordinator.revealForSelectionChange()
            let revealed = try XCTUnwrap(tv.textStorage)
                .attribute(.kern, at: pipe.location, effectiveRange: nil) as? CGFloat

            XCTAssertNotEqual(padded ?? 0, revealed ?? 0,
                              "a revealed row must not keep the padding that stood in "
                              + "for its hidden pipes")
        }
    }

    /// Prose containing a `|` is not a table and must not be touched.
    @MainActor
    func test_proseWithAPipeIsUnaffected() throws {
        let body = "a | b is not a table\n"
        let (coordinator, tv) = editor(body)
        withExtendedLifetime(coordinator) {
            let found = coordinator.cachedSpansForTesting
            XCTAssertFalse(found.contains { $0.kind == .table })
            XCTAssertEqual(tv.string, body)
        }
    }
}
