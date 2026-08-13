import AppKit
import XCTest
@testable import LoreFeature

final class EditorMenuTests: XCTestCase {

    // MARK: - Word lookup

    func test_findsTheWordUnderAnInteriorOffset() {
        let text = "the quikc brown fox"
        let range = try? XCTUnwrap(WordAtPoint.range(in: text, atUTF16: 6))
        XCTAssertEqual((text as NSString).substring(with: range ?? NSRange()), "quikc")
    }

    /// A click at the very start of a word belongs to that word, not the space
    /// before it — otherwise right-clicking a misspelling you just double
    /// clicked offers suggestions for nothing.
    func test_anOffsetAtAWordStartBelongsToThatWord() {
        let text = "the quikc brown"
        let range = try? XCTUnwrap(WordAtPoint.range(in: text, atUTF16: 4))
        XCTAssertEqual((text as NSString).substring(with: range ?? NSRange()), "quikc")
    }

    func test_whitespaceHasNoWord() {
        XCTAssertNil(WordAtPoint.range(in: "the quikc", atUTF16: 3))
    }

    func test_anEmptyDocumentHasNoWord() {
        XCTAssertNil(WordAtPoint.range(in: "", atUTF16: 0))
    }

    /// An offset past the end must return nil rather than trap. This is the
    /// recorded hazard: a test that TRAPS takes the runner down, xcodebuild
    /// restarts it, and the summary then sums across launches — so a crash can
    /// read as a larger passing run.
    func test_anOffsetPastTheEndHasNoWord() {
        XCTAssertNil(WordAtPoint.range(in: "abc", atUTF16: 99))
    }

    // MARK: - Menu construction

    /// With no selection, Cut and Copy are absent rather than present and
    /// dead. A menu that offers what it cannot do teaches the wrong thing.
    func test_withoutASelectionThereIsNoCutOrCopy() {
        let items = EditorMenuItems.build(selection: NSRange(location: 3, length: 0),
                                          suggestions: [],
                                          actions: .noop)
        let titles = items.map(\.title)
        XCTAssertFalse(titles.contains("Cut"))
        XCTAssertFalse(titles.contains("Copy"))
        XCTAssertTrue(titles.contains("Paste"))
        XCTAssertTrue(titles.contains("Select All"))
    }

    func test_withASelectionCutAndCopyAppear() {
        let items = EditorMenuItems.build(selection: NSRange(location: 0, length: 4),
                                          suggestions: [],
                                          actions: .noop)
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Cut"))
        XCTAssertTrue(titles.contains("Copy"))
    }

    /// The markdown actions are the reason this menu exists at all.
    func test_theMarkdownActionsAreAlwaysOffered() {
        let items = EditorMenuItems.build(selection: NSRange(location: 0, length: 4),
                                          suggestions: [],
                                          actions: .noop)
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Link"))
        XCTAssertTrue(titles.contains("Code"))
        XCTAssertTrue(titles.contains("Heading"))
    }

    func test_spellingSuggestionsAppearAboveEverythingElse() {
        let items = EditorMenuItems.build(selection: NSRange(location: 4, length: 5),
                                          suggestions: ["quick", "quick-fire"],
                                          actions: .noop)
        XCTAssertEqual(items.first?.title, "quick")
        XCTAssertTrue(items.map(\.title).contains("Ignore Spelling"))
        XCTAssertTrue(items.map(\.title).contains("Learn Spelling"))
    }

    /// A correctly spelled word yields no suggestions and must not leave an
    /// empty spelling group behind.
    func test_noSuggestionsMeansNoSpellingGroup() {
        let items = EditorMenuItems.build(selection: NSRange(location: 0, length: 3),
                                          suggestions: [],
                                          actions: .noop)
        XCTAssertFalse(items.map(\.title).contains("Ignore Spelling"))
    }
}
