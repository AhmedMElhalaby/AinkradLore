import XCTest
@testable import LoreFeature

@MainActor
final class TabsTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lore-tabs-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func makeStore(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    func test_openTwoDocuments_bothTabsStayOpen() throws {
        let root = tempDir(); let s = try makeStore(root)
        try "---\nid: a\ntitle: A\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "plain".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        s.open(url: root.appendingPathComponent("a.md"))
        s.open(url: root.appendingPathComponent("b.txt"))
        XCTAssertEqual(s.tabs.count, 2)
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "b.txt")
    }

    func test_openingSameDocumentTwice_selectsExistingTab() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        s.open(url: url)
        XCTAssertEqual(s.tabs.count, 1)
    }

    func test_closeTab_selectsNeighbor() throws {
        let root = tempDir(); let s = try makeStore(root)
        try "---\nid: a\ntitle: A\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "plain".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        s.open(url: root.appendingPathComponent("a.md"))
        s.open(url: root.appendingPathComponent("b.txt"))
        s.closeTab(s.selectedTab!)
        XCTAssertEqual(s.tabs.count, 1)
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "a.md")
    }

    func test_openUnsupportedType_recordsErrorWithoutOpeningTab() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("sheet.xlsx")
        try "binary".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        XCTAssertTrue(s.tabs.isEmpty)
        XCTAssertEqual(s.openError?.url, url)
    }

    func test_closeTab_savesDirtySessionBeforeClosing() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        let session = s.selectedTab!
        guard let engine = session.engine as? MarkdownEngine else {
            return XCTFail("expected MarkdownEngine")
        }
        engine.note.body = "edited content"
        session.markChanged()
        XCTAssertTrue(session.isDirty)
        s.closeTab(session)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("edited content"))
    }
}
