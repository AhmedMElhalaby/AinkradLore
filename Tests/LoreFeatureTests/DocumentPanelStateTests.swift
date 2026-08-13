import XCTest
@testable import LoreFeature

final class DocumentPanelStateTests: XCTestCase {

    /// Nothing is open until asked for. The panels used to be permanently
    /// visible below the editor; the default is now closed.
    func test_nothingIsOpenInitially() {
        XCTAssertNil(DocumentPanelState().open)
    }

    func test_togglingOpensThatPanel() {
        var state = DocumentPanelState()
        state.toggle(.outline)
        XCTAssertEqual(state.open, .outline)
    }

    /// The buttons are a SEGMENTED selector, not two independent panels:
    /// asking for Linked mentions while the outline is showing SWAPS the
    /// content rather than stacking a second panel over the editor.
    func test_askingForTheOtherPanelSwapsRatherThanStacks() {
        var state = DocumentPanelState()
        state.toggle(.outline)
        state.toggle(.backlinks)
        XCTAssertEqual(state.open, .backlinks)
    }

    /// A second click on the ACTIVE button closes it.
    func test_togglingTheOpenPanelClosesIt() {
        var state = DocumentPanelState()
        state.toggle(.outline)
        state.toggle(.outline)
        XCTAssertNil(state.open)
    }

    /// Esc closes whatever is open, and is harmless when nothing is.
    func test_dismissClosesAnythingOpen() {
        var state = DocumentPanelState()
        state.toggle(.backlinks)
        state.dismiss()
        XCTAssertNil(state.open)
        state.dismiss()
        XCTAssertNil(state.open)
    }
}
