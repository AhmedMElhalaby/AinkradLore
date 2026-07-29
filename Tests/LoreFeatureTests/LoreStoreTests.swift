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

    func test_allTags_areDedupedAndSorted() throws {
        let root = tempDir(); let s = try makeStore(root)
        var a = try s.create(title: "A"); a.tags = ["zeta", "alpha"]; try s.save(a)
        var b = try s.create(title: "B"); b.tags = ["alpha", "mid"]; try s.save(b)
        XCTAssertEqual(s.allTags, ["alpha", "mid", "zeta"])
    }

    func test_defaultNoteFolder_createsInSubfolderAndPersists() throws {
        let root = tempDir()
        let docs = FakeDocs()
        let idx = root.appendingPathComponent(".index.sqlite")
        let s = LoreStore(documents: docs, indexPath: idx)
        try s.setVaultRootForTesting(root)
        s.setDefaultNoteFolder("inbox")
        let note = try s.create(title: "Captured")
        XCTAssertEqual(note.path.deletingLastPathComponent().lastPathComponent, "inbox")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path.path))
        // A fresh store sharing the same documents restores the setting.
        let s2 = LoreStore(documents: docs, indexPath: idx)
        XCTAssertEqual(s2.defaultNoteFolder, "inbox")
    }

    func test_rebuild_isRecursiveAndPrunesDeleted() throws {
        let root = tempDir(); let s = try makeStore(root)
        let sub = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let deep = sub.appendingPathComponent("deep.md")
        try "---\nid: deep\ntitle: Deep\ntags: []\ncreated: 2026-07-19\nupdated: 2026-07-19\n---\nhi"
            .write(to: deep, atomically: true, encoding: .utf8)
        try s.rebuild()
        XCTAssertTrue(s.rows.contains { $0.id == "deep" }, "recursive scan should find nested notes")
        try FileManager.default.removeItem(at: deep)
        try s.rebuild()
        XCTAssertFalse(s.rows.contains { $0.id == "deep" }, "rebuild should prune deleted files")
    }

    func test_scanVault_indexesEveryEngineOpenableType() throws {
        let root = tempDir()
        try "---\nid: a\ntitle: Note\n---\nalpha".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "beta text".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "gamma".write(
            to: root.appendingPathComponent("c.xlsx"), atomically: true, encoding: .utf8)

        let entries = VaultIndexCoordinator.scanVault(at: root)
        XCTAssertEqual(Set(entries.map(\.type)), ["markdown", "plaintext"],
                       "unclaimed types must not be indexed")
    }

    func test_search_findsPlainTextDocuments() async throws {
        let root = tempDir()
        try "beta needle".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let s = try makeStore(root)
        await s.settleForTesting()
        try s.rebuild()
        XCTAssertEqual(s.search("needle").map(\.title), ["b"])
    }

    /// A vault under a dot-prefixed ancestor (`~/.local/share/notes`, a
    /// `.worktrees/` checkout, a sandbox container) must still index. Judging
    /// the absolute path made those vaults silently empty.
    func test_scanVault_indexesAVaultUnderADotPrefixedAncestor() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(".hidden-\(UUID())", isDirectory: true)
        let root = parent.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try "alpha".write(to: root.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        // ...while a dot directory INSIDE the vault is still skipped.
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "beta".write(to: git.appendingPathComponent("b.txt"),
                         atomically: true, encoding: .utf8)

        let entries = VaultIndexCoordinator.scanVault(at: root)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["a.txt"])
    }

    func test_scanVault_capsIndexedPlaintextButStillSearchesIt() throws {
        let root = tempDir()
        let limit = VaultIndexCoordinator.maxIndexedPlaintextBytes
        // "needle" up front, then well past the cap.
        let big = "needle\n" + String(repeating: "x", count: limit + 5_000)
        try big.write(to: root.appendingPathComponent("big.log"),
                      atomically: true, encoding: .utf8)

        let entries = VaultIndexCoordinator.scanVault(at: root)
        XCTAssertEqual(entries.count, 1)
        XCTAssertLessThanOrEqual(entries[0].payload.plaintext.utf8.count, limit)
        XCTAssertLessThan(entries[0].payload.plaintext.utf8.count, big.utf8.count)

        let index = try LoreIndex(path: root.appendingPathComponent("i.sqlite"))
        try index.replaceAll(with: entries)
        XCTAssertEqual(index.searchOrEmpty("needle").map(\.title), ["big"])
    }

    func test_cappedTruncatesOnAScalarBoundary() {
        let limit = VaultIndexCoordinator.maxIndexedPlaintextBytes
        // Every "é" is 2 UTF-8 bytes; the leading "a" makes the byte cap land
        // in the middle of one.
        let text = "a" + String(repeating: "é", count: limit)
        let capped = VaultIndexCoordinator.capped(text)
        XCTAssertEqual(capped.utf8.count, limit - 1, "half a scalar was kept or too much dropped")
        XCTAssertFalse(capped.unicodeScalars.contains("\u{FFFD}"),
                       "truncation cut through a scalar")
        XCTAssertTrue(capped.dropFirst().allSatisfy { $0 == "é" })
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
