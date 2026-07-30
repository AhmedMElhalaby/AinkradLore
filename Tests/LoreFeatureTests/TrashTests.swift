import XCTest
@testable import LoreFeature

@MainActor
final class TrashTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-trash-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return (root, s)
    }

    func test_trashMovesTheFileOutOfTheVaultWithoutDeletingIt() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        _ = try s.trash(s.rows.first { $0.path.lastPathComponent == "gone.md" }!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(s.rows.allSatisfy { $0.path.lastPathComponent != "gone.md" })
    }

    func test_trashReportsInboundLinkCountWithoutRewritingThem() async throws {
        let (root, s) = try vault()
        let a = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nsee [[Gone]]".write(to: a, atomically: true, encoding: .utf8)
        let gone = root.appendingPathComponent("Gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: gone, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        XCTAssertEqual(s.inboundLinkCount(to: gone), 1)
        let warned = try s.trash(s.rows.first { $0.path.lastPathComponent == "Gone.md" }!)
        XCTAssertEqual(warned, 1)
        // The link is deliberately NOT rewritten: an unresolved link is how the
        // user finds what broke.
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Gone]]"))
    }

    func test_trashClosesAnyTabOnTheDocument() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        s.open(url: url)
        XCTAssertEqual(s.tabs.count, 1)
        _ = try s.trash(s.rows.first { $0.path.lastPathComponent == "gone.md" }!)
        XCTAssertTrue(s.tabs.isEmpty)
    }
}
