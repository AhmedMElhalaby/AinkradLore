import XCTest
@testable import LoreFeature

/// E4T1: the flag that lets both surfaces exist.
final class CM6FlagTests: XCTestCase {

    /// OFF by default. The CodeMirror surface has no link completion, no hover
    /// preview and no Cmd-click yet (that is E2), so defaulting it on would
    /// take working features away from the reader.
    func test_theFlagDefaultsOff() {
        XCTAssertFalse(EditorSettings.default.usesCM6)
        XCTAssertFalse(EditorSettings(density: .standard, measure: .standard,
                                      zoomStep: 0).usesCM6)
    }

    /// It survives a round trip, and — the part that matters — it survives
    /// JSON written before the key existed.
    ///
    /// `EditorSettings` decodes every key with `decodeIfPresent` precisely so
    /// an old install does not fall back to `.default` for the WHOLE struct and
    /// silently discard the reader's density, measure and zoom. A new key is
    /// the case that rule exists for, so it is tested rather than trusted.
    func test_theFlagSurvivesEncodingAndOldSettingsFilesStillDecode() throws {
        var settings = EditorSettings.default
        settings.usesCM6 = true
        settings.density = .comfortable
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(EditorSettings.self, from: data)
        XCTAssertEqual(back, settings)

        // JSON from before this key existed.
        let old = #"{"density":"compact","measure":"wide","zoomStep":2}"#
        let decoded = try JSONDecoder().decode(EditorSettings.self,
                                               from: Data(old.utf8))
        XCTAssertFalse(decoded.usesCM6, "an absent key means off")
        XCTAssertEqual(decoded.density, .compact, "and must not reset what WAS set")
        XCTAssertEqual(decoded.measure, .wide)
        XCTAssertEqual(decoded.zoomStep, 2)
    }

    /// Zoom and reset carry it, or flipping the text size would silently put
    /// the reader back on the other editor.
    func test_zoomAndResetPreserveTheFlag() {
        var settings = EditorSettings.default
        settings.usesCM6 = true
        XCTAssertTrue(settings.zoomed(by: 2).usesCM6)
        XCTAssertTrue(settings.zoomReset().usesCM6)
    }
}
