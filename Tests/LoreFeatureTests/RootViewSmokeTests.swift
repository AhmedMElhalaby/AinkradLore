import XCTest
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

@MainActor
final class RootViewSmokeTests: XCTestCase {
    func test_rootView_buildsWithoutVault() {
        let store = LoreStore(documents: FakeDocs(),
            indexPath: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite"))
        _ = LoreRootView(store: store, theme: HostTheme(TestTokens.make()))
    }
}

enum TestTokens {
    static func make() -> HostThemeTokens {
        HostThemeTokens(themeID: "t", background: .black, surface: .gray, surfaceElevated: .gray,
            accentPrimary: .blue, accentSecondary: .teal, accentTertiary: .green, foreground: .white)
    }
}
