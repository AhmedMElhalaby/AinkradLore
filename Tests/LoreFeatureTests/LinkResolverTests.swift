import XCTest
@testable import LoreFeature

final class LinkResolverTests: XCTestCase {
    private func resolver(_ docs: [(String, String, [String])]) -> LinkResolver {
        LinkResolver(documents: docs.map {
            (url: URL(fileURLWithPath: $0.0), title: $0.1, aliases: $0.2)
        })
    }

    func test_resolvesByBasenameIgnoringFolderAndExtension() {
        let r = resolver([("/v/Projects/Design.md", "Design", [])])
        XCTAssertEqual(r.resolve("Design")?.path, "/v/Projects/Design.md")
    }

    func test_resolutionIsCaseInsensitive() {
        let r = resolver([("/v/Design.md", "Design", [])])
        XCTAssertEqual(r.resolve("design")?.path, "/v/Design.md")
    }

    func test_ignoresHeadingFragment() {
        let r = resolver([("/v/Design.md", "Design", [])])
        XCTAssertEqual(r.resolve("Design#Overview")?.path, "/v/Design.md")
        XCTAssertEqual(r.resolve("Design#^abc")?.path, "/v/Design.md")
    }

    func test_resolvesByFrontmatterAlias() {
        let r = resolver([("/v/Design.md", "Design", ["Spec", "Design Doc"])])
        XCTAssertEqual(r.resolve("Spec")?.path, "/v/Design.md")
    }

    func test_ambiguousBasenameResolvesToShortestPath() {
        let r = resolver([
            ("/v/Archive/Deep/Design.md", "Design", []),
            ("/v/Design.md", "Design", []),
        ])
        XCTAssertEqual(r.resolve("Design")?.path, "/v/Design.md")
    }

    func test_explicitPathDisambiguates() {
        let r = resolver([
            ("/v/Archive/Design.md", "Design", []),
            ("/v/Design.md", "Design", []),
        ])
        XCTAssertEqual(r.resolve("Archive/Design")?.path, "/v/Archive/Design.md")
    }

    func test_unresolvedTargetReturnsNil() {
        let r = resolver([("/v/Design.md", "Design", [])])
        XCTAssertNil(r.resolve("Nonexistent"))
    }

    func test_explicitPathWithExtensionResolves() {
        let r = resolver([("/v/Notes/Design.md", "Design", [])])
        XCTAssertEqual(r.resolve("Notes/Design.md")?.path, "/v/Notes/Design.md")
    }

    /// Pins the CRITICAL determinism bug: two documents at EQUAL-length paths
    /// both matching an explicit suffix must resolve to the same one
    /// regardless of the order they were passed to `init` — never to whichever
    /// happened to land first in `Dictionary.values`'s randomized iteration
    /// order. The tiebreak is lexicographic on the full path.
    func test_explicitPathAmbiguousEqualLengthResolvesLexicographicallyRegardlessOfInputOrder() {
        let a = ("/v/Aaa/Notes/Design.md", "Design", [String]())
        let b = ("/v/Bbb/Notes/Design.md", "Design", [String]())

        let forward = resolver([a, b])
        let reversed = resolver([b, a])

        // Both paths are the same length; "/v/Aaa/..." < "/v/Bbb/..." lexicographically.
        XCTAssertEqual(forward.resolve("Notes/Design")?.path, "/v/Aaa/Notes/Design.md")
        XCTAssertEqual(reversed.resolve("Notes/Design")?.path, "/v/Aaa/Notes/Design.md")
    }

    /// Pins the same class of bug one step quieter: equal-length basename
    /// collisions (no explicit path in the link) must resolve identically
    /// regardless of input order, via the lexicographic tiebreak in `byKey`.
    func test_basenameAmbiguousEqualLengthResolvesLexicographicallyRegardlessOfInputOrder() {
        let a = ("/v/Aaa/Design.md", "Design", [String]())
        let b = ("/v/Bbb/Design.md", "Design", [String]())

        let forward = resolver([a, b])
        let reversed = resolver([b, a])

        XCTAssertEqual(forward.resolve("Design")?.path, "/v/Aaa/Design.md")
        XCTAssertEqual(reversed.resolve("Design")?.path, "/v/Aaa/Design.md")
    }
}
