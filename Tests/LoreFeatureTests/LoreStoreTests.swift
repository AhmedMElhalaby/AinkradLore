import XCTest
@testable import LoreFeature
import AinkradAppKit

final class FakeDocs: PluginDocumentStore {
    private var store: [String: Data] = [:]
    func data(forKey key: String) -> Data? { store[key] }
    func setData(_ data: Data?, forKey key: String) { store[key] = data }
}

@MainActor
final class LoreStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lore-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func makeStore(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)   // bypasses security-scoped bookmark in tests
        return s
    }

    func test_create_writesFileAndIndexes() throws {
        let root = tempDir(); let s = try makeStore(root)
        let note = try s.create(title: "First")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path.path))
        XCTAssertEqual(s.rows.map(\.title), ["First"])
    }

    func test_save_updatesBodyAndSearch() throws {
        let root = tempDir(); let s = try makeStore(root)
        var note = try s.create(title: "Note")
        note.body = "searchable haystack"
        try s.save(note)
        XCTAssertEqual(s.search("haystack").map(\.id), [note.id])
    }

    func test_delete_removesFileAndRow() throws {
        let root = tempDir(); let s = try makeStore(root)
        let note = try s.create(title: "Trash")
        try s.delete(s.rows.first { $0.id == note.id }!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path.path))
        XCTAssertTrue(s.rows.isEmpty)
    }

    func test_rebuild_picksUpExternalFile() throws {
        let root = tempDir(); let s = try makeStore(root)
        let ext = root.appendingPathComponent("outside.md")
        try "---\nid: ext\ntitle: Outside\ntags: []\ncreated: 2026-07-19\nupdated: 2026-07-19\n---\nhi"
            .write(to: ext, atomically: true, encoding: .utf8)
        try s.rebuild()
        XCTAssertTrue(s.rows.contains { $0.id == "ext" })
    }

    func test_externalChange_flagsOpenNote() throws {
        let root = tempDir(); let s = try makeStore(root)
        let note = try s.create(title: "Open")
        usleep(20_000)  // ensure the external write lands on a later mtime tick
        // simulate external edit bumping mtime
        try "changed".write(to: note.path, atomically: true, encoding: .utf8)
        XCTAssertTrue(s.externalChangeDetected(for: note))
    }
}
