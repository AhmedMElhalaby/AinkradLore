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
}
