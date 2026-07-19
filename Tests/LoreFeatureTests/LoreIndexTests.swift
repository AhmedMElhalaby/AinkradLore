import XCTest
@testable import LoreFeature

final class LoreIndexTests: XCTestCase {
    private func makeIndex() throws -> LoreIndex {
        try LoreIndex(path: URL(fileURLWithPath: "/tmp/lore-index-\(UUID()).sqlite"))
    }
    private func note(_ name: String, title: String, body: String) -> Note {
        Note(path: URL(fileURLWithPath: "/tmp/v/\(name).md"), id: name, title: title,
             tags: ["t"], created: Date(), updated: Date(), body: body)
    }

    func test_upsert_thenAll_returnsRow() throws {
        let idx = try makeIndex()
        try idx.upsert(note("a", title: "Alpha", body: "hello world"))
        XCTAssertEqual(try idx.all().map(\.title), ["Alpha"])
    }

    func test_search_matchesBody() throws {
        let idx = try makeIndex()
        try idx.upsert(note("a", title: "Alpha", body: "the quick brown fox"))
        try idx.upsert(note("b", title: "Beta", body: "lazy dog sleeps"))
        XCTAssertEqual(try idx.search("brown").map(\.id), ["a"])
        XCTAssertEqual(try idx.search("Beta").map(\.id), ["b"])   // title is indexed too
    }

    func test_remove_dropsRow() throws {
        let idx = try makeIndex()
        try idx.upsert(note("a", title: "Alpha", body: "x"))
        try idx.remove(path: URL(fileURLWithPath: "/tmp/v/a.md"))
        XCTAssertTrue(try idx.all().isEmpty)
    }
}
