import XCTest
@testable import LoreFeature

/// Pinned and recent documents.
@MainActor
final class ShortcutListsTests: XCTestCase {

    private func vault(_ label: String = "shortcuts") throws -> (URL, LoreStore, FakeDocs) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let docs = FakeDocs()
        let store = LoreStore(documents: docs,
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store, docs)
    }

    @discardableResult
    private func note(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try "---\nid: \(name)\ntitle: \(name)\n---\nbody".write(
            to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Recents

    func test_openingADocumentPutsItAtTheTopOfRecents() async throws {
        let (root, store, _) = try vault()
        let a = try note(root, "a.md"), b = try note(root, "b.md")
        await store.settleForTesting(); try store.rebuild()

        store.open(url: a)
        store.open(url: b)
        XCTAssertEqual(store.recentRows.map(\.path.lastPathComponent), ["b.md", "a.md"])

        // Re-opening MOVES it rather than adding a duplicate.
        store.open(url: a)
        XCTAssertEqual(store.recentRows.map(\.path.lastPathComponent), ["a.md", "b.md"])
    }

    func test_recentsAreCapped() async throws {
        let (root, store, _) = try vault("recents-cap")
        for i in 0..<(LoreStore.recentsLimit + 5) {
            store.open(url: try note(root, "n\(i).md"))
        }
        await store.settleForTesting(); try store.rebuild()
        XCTAssertLessThanOrEqual(store.recentPaths.count, LoreStore.recentsLimit)
    }

    /// A deleted or renamed document simply stops resolving. This is the whole
    /// reason the lists store PATHS and filter through `rows`: the alternative
    /// is a shortcut row that errors when clicked.
    func test_aTrashedDocumentDisappearsFromRecents() async throws {
        let (root, store, _) = try vault("recents-ghost")
        let a = try note(root, "a.md")
        await store.settleForTesting(); try store.rebuild()
        store.open(url: a)
        XCTAssertEqual(store.recentRows.count, 1)

        let row = try XCTUnwrap(store.rows.first { $0.path.lastPathComponent == "a.md" })
        _ = try store.trash(row)

        XCTAssertTrue(store.recentRows.isEmpty,
                      "a shortcut to a file that no longer exists must not be offered")
    }

    // MARK: - Pinned

    func test_pinningIsAToggleAndSurvivesARelaunch() async throws {
        let (root, store, docs) = try vault("pin")
        let a = try note(root, "a.md")
        await store.settleForTesting(); try store.rebuild()

        XCTAssertFalse(store.isPinned(a))
        store.togglePinned(a)
        XCTAssertTrue(store.isPinned(a))
        XCTAssertEqual(store.pinnedRows.map(\.path.lastPathComponent), ["a.md"])

        let reopened = LoreStore(documents: docs,
                                 indexPath: root.appendingPathComponent(".idx.sqlite"))
        try reopened.setVaultRootForTesting(root)
        await reopened.settleForTesting(); try reopened.rebuild()
        XCTAssertTrue(reopened.isPinned(a), "a pin must survive a relaunch")

        reopened.togglePinned(a)
        XCTAssertFalse(reopened.isPinned(a))
    }

    /// A document in both lists would take two rows in a section whose whole
    /// purpose is to be short.
    func test_apinnedDocumentIsNotAlsoListedAsRecent() async throws {
        let (root, store, _) = try vault("pin-recent")
        let a = try note(root, "a.md"), b = try note(root, "b.md")
        await store.settleForTesting(); try store.rebuild()
        store.open(url: a)
        store.open(url: b)
        store.togglePinned(a)

        XCTAssertEqual(store.pinnedRows.map(\.path.lastPathComponent), ["a.md"])
        XCTAssertEqual(store.recentRows.map(\.path.lastPathComponent), ["b.md"])
    }

    func test_pinnedRowsDropADeletedDocument() async throws {
        let (root, store, _) = try vault("pin-ghost")
        let a = try note(root, "a.md")
        await store.settleForTesting(); try store.rebuild()
        store.togglePinned(a)
        XCTAssertEqual(store.pinnedRows.count, 1)

        let row = try XCTUnwrap(store.rows.first { $0.path.lastPathComponent == "a.md" })
        _ = try store.trash(row)
        XCTAssertTrue(store.pinnedRows.isEmpty)
    }
}
