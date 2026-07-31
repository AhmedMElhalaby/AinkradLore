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

extension MarkdownEditingTests {
    private func indent(_ text: String, at location: Int, by delta: Int) -> EditResult? {
        MarkdownEditing.indent(text: text,
                               selection: NSRange(location: location, length: 0), by: delta)
    }

    func test_tabIndentsTheItemUnderTheCaret() {
        XCTAssertEqual(indent("- item", at: 3, by: 1)?.text, "  - item")
    }

    func test_shiftTabOutdents() {
        XCTAssertEqual(indent("  - item", at: 5, by: -1)?.text, "- item")
    }

    func test_outdentAtColumnZeroIsANoOpRatherThanADeletion() {
        XCTAssertEqual(indent("- item", at: 3, by: -1)?.text, "- item")
    }

    /// Renumbering: an ordered item that moves must not keep a number from its
    /// old level.
    func test_indentingAnOrderedItemRestartsItsNumbering() {
        XCTAssertEqual(indent("1. a\n2. b", at: 7, by: 1)?.text, "1. a\n  1. b")
    }

    /// Tab outside a list must not be swallowed — it should insert a tab.
    func test_tabInProseIsNotHandled() {
        XCTAssertNil(indent("prose", at: 3, by: 1))
    }
}

extension MarkdownEditingTests {

    func test_cmdBWrapsTheSelection() {
        let r = MarkdownEditing.toggleWrap(text: "make bold now",
                                           selection: NSRange(location: 5, length: 4),
                                           with: "**")
        XCTAssertEqual(r.text, "make **bold** now")
    }

    /// The same keystroke unwraps — a toggle, not an "add more asterisks".
    func test_cmdBOnAlreadyBoldTextUnwrapsIt() {
        let r = MarkdownEditing.toggleWrap(text: "make **bold** now",
                                           selection: NSRange(location: 7, length: 4),
                                           with: "**")
        XCTAssertEqual(r.text, "make bold now")
    }

    func test_cmdBWithNoSelectionInsertsAnEmptyPairWithTheCaretInside() {
        let r = MarkdownEditing.toggleWrap(text: "ab", selection: NSRange(location: 1, length: 0),
                                           with: "**")
        XCTAssertEqual(r.text, "a****b")
        XCTAssertEqual(r.selection.location, 3)
    }

    /// Losing a selection to a stray bracket is a small data loss, so
    /// auto-pair SURROUNDS a selection rather than replacing it.
    func test_autoPairSurroundsASelectionInsteadOfReplacingIt() {
        let r = MarkdownEditing.autoPair(text: "keep me",
                                         selection: NSRange(location: 5, length: 2), typing: "[")
        XCTAssertEqual(r?.text, "keep [me]")
    }

    func test_autoPairInsertsTheClosingCharacter() {
        let r = MarkdownEditing.autoPair(text: "", selection: NSRange(location: 0, length: 0),
                                         typing: "[")
        XCTAssertEqual(r?.text, "[]")
        XCTAssertEqual(r?.selection.location, 1)
    }

    /// Typing the closing character when it is already there moves past it
    /// rather than doubling it.
    func test_typingAClosingCharacterOverATypedOneSkipsIt() {
        let r = MarkdownEditing.autoPair(text: "[]", selection: NSRange(location: 1, length: 0),
                                         typing: "]")
        XCTAssertEqual(r?.text, "[]")
        XCTAssertEqual(r?.selection.location, 2)
    }

    func test_autoPairIgnoresUnpairedCharacters() {
        XCTAssertNil(MarkdownEditing.autoPair(text: "", selection: NSRange(location: 0, length: 0),
                                              typing: "z"))
    }
}
