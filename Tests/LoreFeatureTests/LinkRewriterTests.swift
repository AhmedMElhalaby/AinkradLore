import XCTest
@testable import LoreFeature

final class LinkRewriterTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/v")

    func test_planRewritesBareTargetToNewBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design")],
            vaultRoot: root)
        XCTAssertEqual(plan.edits,
                       [LinkEdit(file: URL(fileURLWithPath: "/v/A.md"),
                                 oldTarget: "Design", newTarget: "Architecture")])
    }

    func test_planPreservesHeadingFragment() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design#Overview")],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Architecture#Overview")
    }

    func test_planPreservesTheAuthorsPathStyle() {
        // A link written with an explicit folder keeps one; a bare link stays bare.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Projects/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Projects/Design")],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Architecture")
    }

    func test_planPreservesMarkdownExtensionStyle() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md")],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Architecture.md")
    }

    func test_affectedFilesAreDeduplicated() {
        let a = URL(fileURLWithPath: "/v/A.md")
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(a, "Design"), (a, "Design#Two")],
            vaultRoot: root)
        XCTAssertEqual(plan.affectedFiles, [a])
        XCTAssertEqual(plan.edits.count, 2)
    }

    func test_moveWithoutRenameStillProducesNoEditsForBareLinks() {
        // Moving Design.md into a folder does not change a bare `[[Design]]`.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design")],
            vaultRoot: root)
        XCTAssertTrue(plan.edits.isEmpty)
    }

    func test_moveRewritesExplicitPathLinks() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md")],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Design.md")
    }
}
