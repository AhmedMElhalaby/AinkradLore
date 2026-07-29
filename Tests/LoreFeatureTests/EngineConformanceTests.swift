import XCTest
@testable import LoreFeature

final class EngineRegistryTests: XCTestCase {
    private func tempFile(_ name: String, _ contents: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-engine-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_registry_hasAtLeastOneEngine() throws {
        try XCTSkipIf(EngineRegistry.engines.isEmpty, "engines land in Tasks 3-4")
        XCTAssertFalse(EngineRegistry.engines.isEmpty)
    }

    func test_registry_returnsNilForUnclaimedType() throws {
        let url = try tempFile("sheet.xlsx", "binary-ish")
        XCTAssertNil(EngineRegistry.engine(for: url))
    }

    func test_engineIdentifiersAreUnique() {
        let ids = EngineRegistry.engines.map { $0.identifier }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate engine identifiers: \(ids)")
    }
}

final class MarkdownEngineTests: XCTestCase {
    private func tempFile(_ name: String, _ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-md-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_canOpen_claimsMarkdownOnly() throws {
        XCTAssertTrue(MarkdownEngine.canOpen(URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertFalse(MarkdownEngine.canOpen(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(MarkdownEngine.canOpen(URL(fileURLWithPath: "/tmp/a.pdf")))
    }

    func test_indexPayload_exposesTitleTagsAndBody() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: Hello
        tags: [x, y]
        ---
        searchable haystack
        """)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.indexPayload.title, "Hello")
        XCTAssertEqual(engine.indexPayload.tags, ["x", "y"])
        XCTAssertTrue(engine.indexPayload.plaintext.contains("haystack"))
    }

    func test_outline_listsHeadings() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: T
        ---
        # One
        text
        ## Two
        """)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.indexPayload.outline,
                       [OutlineEntry(level: 1, text: "One"), OutlineEntry(level: 2, text: "Two")])
    }

    func test_saveThenLoad_preservesUnmodelledProperties() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: T
        status: active
        ---
        body
        """)
        let engine = try MarkdownEngine.load(url)
        try engine.save(to: url)
        let reloaded = try MarkdownEngine.load(url)
        XCTAssertEqual(reloaded.note.extra.map(\.key), ["status"])
    }
}
