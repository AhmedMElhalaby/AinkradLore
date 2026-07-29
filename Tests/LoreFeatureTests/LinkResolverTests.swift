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
}
