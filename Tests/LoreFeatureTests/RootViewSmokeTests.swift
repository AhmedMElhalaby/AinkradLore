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

    private func tempVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func test_rootView_buildsWithoutVault() {
        _ = LoreRootView(store: makeStore(), theme: HostTheme(TestTokens.make()))
    }

    func test_settingsView_builds() {
        _ = LoreSettingsView(store: makeStore(), theme: HostTheme(TestTokens.make()))
    }

    func test_documentPane_buildsForEachOpenTab() throws {
        let root = try tempVault()
        try "---\nid: a\ntitle: A\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "plain".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        store.open(url: root.appendingPathComponent("a.md"))
        store.open(url: root.appendingPathComponent("b.txt"))
        XCTAssertEqual(store.tabs.count, 2)
        for session in store.tabs {
            _ = DocumentPane(store: store, session: session,
                             theme: HostTheme(TestTokens.make()))
        }
        _ = TabBarView(store: store, theme: HostTheme(TestTokens.make()))
    }

    func test_fallbackViewer_builds() {
        let url = URL(fileURLWithPath: "/tmp/x.xlsx")
        _ = FallbackViewer(url: url, error: EngineError.unsupported(url),
                           theme: HostTheme(TestTokens.make()))
        _ = FallbackViewer(url: url, error: nil, theme: HostTheme(TestTokens.make()))
    }

    /// The delete affordance moved from `NoteEditorPane` to the list row's
    /// context menu; its store-level effect is testable without a view host.
    func test_deleteDocument_removesFileAndClosesOnlyItsTab() throws {
        let root = try tempVault()
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: a, atomically: true, encoding: .utf8)
        try "---\nid: b\ntitle: B\n---\ny".write(to: b, atomically: true, encoding: .utf8)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        store.open(url: a)
        store.open(url: b)
        XCTAssertEqual(store.tabs.count, 2)

        let row = IndexRow(path: a, id: "a", title: "A", tags: [], updated: Date(),
                           type: MarkdownEngine.identifier, properties: [])
        deleteDocument(row, in: store)

        XCTAssertEqual(store.tabs.map(\.url), [b])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    /// A reload must be visible in the editor. `DocumentPane` composes the
    /// editor's identity from `reloadGeneration`, so this asserts the value
    /// that identity is built from actually changes.
    func test_reload_bumpsGenerationSoEditorIdentityChanges() throws {
        let root = try tempVault()
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        store.open(url: url)
        let session = try XCTUnwrap(store.selectedTab)
        let before = session.reloadGeneration
        try "---\nid: a\ntitle: A\n---\nchanged".write(to: url, atomically: true, encoding: .utf8)
        try session.resolveByReloading()
        XCTAssertEqual(session.reloadGeneration, before + 1)
    }
}

enum TestTokens {
    static func make() -> HostThemeTokens {
        HostThemeTokens(themeID: "t", background: .black, surface: .gray, surfaceElevated: .gray,
            accentPrimary: .blue, accentSecondary: .teal, accentTertiary: .green, foreground: .white)
    }
}
