import XCTest
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

@MainActor
final class RootViewSmokeTests: XCTestCase {
    private func makeStore() -> LoreStore {
        LoreStore(documents: FakeDocs(),
            indexPath: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite"))
    }

    func test_rootView_buildsWithoutVault() {
        _ = LoreRootView(store: makeStore(), theme: HostTheme(TestTokens.make()))
    }

    func test_settingsView_builds() {
        _ = LoreSettingsView(store: makeStore(), theme: HostTheme(TestTokens.make()))
    }

    func test_editorPane_builds() {
        let note = Note(path: URL(fileURLWithPath: "/tmp/x.md"), id: "id", title: "T",
                        tags: [], created: Date(), updated: Date(), body: "# Hi")
        _ = NoteEditorPane(store: makeStore(), note: note,
                           theme: HostTheme(TestTokens.make()), onDelete: {})
    }
}

enum TestTokens {
    static func make() -> HostThemeTokens {
        HostThemeTokens(themeID: "t", background: .black, surface: .gray, surfaceElevated: .gray,
            accentPrimary: .blue, accentSecondary: .teal, accentTertiary: .green, foreground: .white)
    }
}
