import XCTest
@testable import LoreFeature

final class FrontmatterTests: XCTestCase {
    private let path = URL(fileURLWithPath: "/tmp/lore/sample.md")

    func test_parse_wellFormed() {
        let text = """
        ---
        id: abc-123
        title: My Note
        tags: [work, ideas]
        created: 2026-07-19
        updated: 2026-07-19
        ---
        Hello body
        """
        let note = Frontmatter.parse(text, path: path)
        XCTAssertEqual(note.id, "abc-123")
        XCTAssertEqual(note.title, "My Note")
        XCTAssertEqual(note.tags, ["work", "ideas"])
        XCTAssertEqual(note.body, "Hello body")
    }

    func test_parse_missingFrontmatter_fallsBackToBodyAndFilename() {
        let note = Frontmatter.parse("# Heading\nplain", path: path)
        XCTAssertEqual(note.title, "Heading")          // first heading wins
        XCTAssertEqual(note.body, "# Heading\nplain")  // whole text is body
        XCTAssertFalse(note.id.isEmpty)                // synthesized
    }

    func test_roundTrip_isStable() {
        let text = Frontmatter.serialize(Frontmatter.parse("""
        ---
        id: r1
        title: Round
        tags: [a]
        created: 2026-07-19
        updated: 2026-07-19
        ---
        body text
        """, path: path))
        let reparsed = Frontmatter.parse(text, path: path)
        XCTAssertEqual(reparsed.id, "r1")
        XCTAssertEqual(reparsed.title, "Round")
        XCTAssertEqual(reparsed.tags, ["a"])
        XCTAssertEqual(reparsed.body, "body text")
    }

    func test_parse_capturesUnmodelledKeysInOrder() {
        let text = """
        ---
        id: abc
        aliases: [one, two]
        title: Kept
        status: active
        ---
        body text
        """
        let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertEqual(note.extra.map(\.key), ["aliases", "status"])
        XCTAssertEqual(note.extra.first?.rawValue, "[one, two]")
    }

    func test_serialize_reemitsUnmodelledKeys() {
        let text = """
        ---
        id: abc
        title: Kept
        status: active
        cssclasses: wide
        ---
        body text
        """
        let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/x.md"))
        let out = Frontmatter.serialize(note)
        XCTAssertTrue(out.contains("status: active"), out)
        XCTAssertTrue(out.contains("cssclasses: wide"), out)
    }

    func test_roundTrip_isStableAcrossTwoPasses() {
        let text = """
        ---
        id: abc
        title: Kept
        tags: [a, b]
        created: 2026-01-01
        updated: 2026-01-02
        source: https://example.com
        ---
        body text
        """
        let path = URL(fileURLWithPath: "/tmp/x.md")
        let once = Frontmatter.serialize(Frontmatter.parse(text, path: path))
        let twice = Frontmatter.serialize(Frontmatter.parse(once, path: path))
        XCTAssertEqual(once, twice)
    }
}
