import XCTest
import GRDB
@testable import LoreFeature

final class LoreIndexTests: XCTestCase {
    private func makeIndex() throws -> LoreIndex {
        try LoreIndex(path: URL(fileURLWithPath: "/tmp/lore-index-\(UUID()).sqlite"))
    }
    private func entry(_ name: String, title: String, body: String) -> IndexEntry {
        IndexEntry(url: URL(fileURLWithPath: "/tmp/v/\(name).md"),
                   type: "markdown",
                   payload: IndexPayload(title: title, plaintext: body, tags: ["t"], id: name),
                   updated: Date())
    }

    func test_upsert_thenAll_returnsRow() throws {
        let idx = try makeIndex()
        try idx.upsert(entry("a", title: "Alpha", body: "hello world"))
        XCTAssertEqual(try idx.all().map(\.title), ["Alpha"])
    }

    func test_search_matchesBody() throws {
        let idx = try makeIndex()
        try idx.upsert(entry("a", title: "Alpha", body: "the quick brown fox"))
        try idx.upsert(entry("b", title: "Beta", body: "lazy dog sleeps"))
        XCTAssertEqual(try idx.search("brown").map(\.id), ["a"])
        XCTAssertEqual(try idx.search("Beta").map(\.id), ["b"])   // title is indexed too
    }

    func test_remove_dropsRow() throws {
        let idx = try makeIndex()
        try idx.upsert(entry("a", title: "Alpha", body: "x"))
        try idx.remove(path: URL(fileURLWithPath: "/tmp/v/a.md"))
        XCTAssertTrue(try idx.all().isEmpty)
    }

    func test_indexesEntriesOfAnyType() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        let index = try LoreIndex(path: dbURL)
        let entry = IndexEntry(
            url: URL(fileURLWithPath: "/tmp/a.txt"),
            type: "plaintext",
            payload: IndexPayload(title: "A", plaintext: "needle in here"),
            updated: Date())
        try index.replaceAll(with: [entry])
        XCTAssertEqual(try index.all().map(\.type), ["plaintext"])
        XCTAssertEqual(index.searchOrEmpty("needle").map(\.title), ["A"])
    }

    func test_storesProperties() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        let index = try LoreIndex(path: dbURL)
        let entry = IndexEntry(
            url: URL(fileURLWithPath: "/tmp/a.md"),
            type: "markdown",
            payload: IndexPayload(title: "A", plaintext: "b",
                                  properties: [FrontmatterPair(key: "status", rawValue: "active")]),
            updated: Date())
        try index.replaceAll(with: [entry])
        XCTAssertEqual(try index.all().first?.properties.first?.key, "status")
    }

    /// A corrupt index must cost a rescan, never the vault: if `init` threw,
    /// `activate` would fail and the user's notes would never open again.
    func test_corruptIndexFileSelfHeals() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        try Data(repeating: 0xAB, count: 4096).write(to: dbURL)

        let index = try LoreIndex(path: dbURL)
        try index.upsert(entry("a", title: "Alpha", body: "recovered needle"))
        XCTAssertEqual(index.searchOrEmpty("needle").map(\.title), ["Alpha"])
    }

    func test_staleSchemaIsRebuiltNotRead() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        // Create a v1-shaped database by hand.
        let legacy = try DatabaseQueue(path: dbURL.path)
        try legacy.write { db in
            try db.execute(sql: "PRAGMA user_version = 1;")
            try db.execute(sql: "CREATE TABLE notes(path TEXT PRIMARY KEY);")
            try db.execute(sql: "INSERT INTO notes(path) VALUES('/tmp/old.md');")
        }
        _ = legacy   // release before reopening

        let index = try LoreIndex(path: dbURL)
        XCTAssertTrue(try index.all().isEmpty, "stale index should be discarded, not read")
    }
}
