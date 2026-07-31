import XCTest
@testable import LoreFeature

/// Typing affordances as PURE transforms, so every rule is asserted without an
/// AppKit text view.
final class MarkdownEditingTests: XCTestCase {

    private func enter(_ text: String, at location: Int) -> EditResult? {
        MarkdownEditing.continueList(text: text, selection: NSRange(location: location, length: 0))
    }

    func test_enterContinuesABulletList() {
        let r = enter("- first", at: 7)
        XCTAssertEqual(r?.text, "- first\n- ")
        XCTAssertEqual(r?.selection.location, 10)
    }

    func test_enterIncrementsAnOrderedList() {
        XCTAssertEqual(enter("1. first", at: 8)?.text, "1. first\n2. ")
    }

    func test_enterContinuesATaskAsUnchecked() {
        // A continued task starts unchecked — copying `[x]` would assert the
        // new item is already done.
        XCTAssertEqual(enter("- [x] done", at: 10)?.text, "- [x] done\n- [ ] ")
    }

    func test_enterPreservesIndentation() {
        XCTAssertEqual(enter("  - nested", at: 10)?.text, "  - nested\n  - ")
    }

    /// The rule that makes auto-continue a help rather than a nuisance:
    /// Enter on an EMPTY item ends the list instead of adding another.
    func test_enterOnAnEmptyItemEndsTheList() {
        let r = enter("- first\n- ", at: 10)
        XCTAssertEqual(r?.text, "- first\n")
        XCTAssertEqual(r?.selection.location, 8)
    }

    /// Not a list: return nil so AppKit inserts a plain newline and undo,
    /// autocorrect and everything else behave normally.
    func test_enterInProseIsNotHandled() {
        XCTAssertNil(enter("just prose", at: 10))
    }

    /// A CRLF document must continue correctly — "\r\n" is two UTF-16 units.
    func test_enterContinuesAListInACRLFDocument() {
        XCTAssertEqual(enter("- a\r\n- b", at: 8)?.text, "- a\r\n- b\n- ")
    }
}
