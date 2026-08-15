import XCTest
@testable import LoreFeature

/// The slideover's selector.
///
/// `DocumentPanel` has ONE case now: the outline left to become
/// `LoreSpineRail`, which is always present and costs no layout. That removed
/// this suite's `test_askingForTheOtherPanelSwapsRatherThanStacks` — with a
/// single panel there is no "other" to ask for, so the swap-versus-stack rule
/// is currently unobservable rather than broken. `DocumentPanelState.toggle`
/// still implements it, and the test comes back the moment a second panel
/// does; deleting it silently would have hidden that.
final class DocumentPanelStateTests: XCTestCase {

    /// Nothing is open until asked for. The panels used to be permanently
    /// visible below the editor; the default is now closed.
    func test_nothingIsOpenInitially() {
        XCTAssertNil(DocumentPanelState().open)
    }

    func test_togglingOpensThatPanel() {
        var state = DocumentPanelState()
        state.toggle(.backlinks)
        XCTAssertEqual(state.open, .backlinks)
    }

    /// A second click on the ACTIVE button closes it.
    func test_togglingTheOpenPanelClosesIt() {
        var state = DocumentPanelState()
        state.toggle(.backlinks)
        state.toggle(.backlinks)
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
