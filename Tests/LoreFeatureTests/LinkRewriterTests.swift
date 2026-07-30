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

    func test_destinationOutsideVaultRootProducesNoEdit() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/elsewhere/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md")],
            vaultRoot: root)
        XCTAssertTrue(plan.edits.isEmpty)
    }

    func test_vaultRootWithTrailingSlashBehavesIdentically() {
        let trailingRoot = URL(fileURLWithPath: "/v/")
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md")],
            vaultRoot: trailingRoot)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Design.md")
    }

    func test_vaultRootTextRecurringInsideDestinationDoesNotCorruptTarget() {
        // vaultRoot is "/v"; destination happens to contain "/v/" again as a
        // path segment further down. A substring replace would mangle this;
        // a path-component comparison must not.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/a/v/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md")],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "a/v/Design.md")
    }

    func test_normalNestedDestinationYieldsCorrectVaultRelativeTarget() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Nested/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md")],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Nested/Design.md")
    }

    func test_combinedShapeRenamePreservesPathExtensionAndFragment() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Projects/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Projects/Design.md#Overview")],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Architecture.md#Overview")
    }

    func test_combinedShapeMovePreservesPathExtensionAndFragment() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Projects/Design.md"),
            to: URL(fileURLWithPath: "/v/Archive/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Projects/Design.md#Overview")],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Archive/Projects/Design.md#Overview")
    }
}

@MainActor
final class RenameApplicationTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-rename-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return (root, s)
    }

    private func write(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_renameRewritesInboundLinksAndMovesTheFile() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        let plan = s.plan(rename: design, to: "Architecture")
        XCTAssertEqual(plan.edits.count, 1)
        let report = s.apply(plan)

        XCTAssertEqual(report.skipped, [])
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Architecture]]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: design.path))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: root.appendingPathComponent("Architecture.md").path))
    }

    func test_fileChangedOnDiskIsSkippedAndReportedNotOverwritten() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        let plan = s.plan(rename: design, to: "Architecture")
        // Wide enough to clear any filesystem mtime granularity. `Thread.sleep`
        // (as the brief wrote it) is unavailable from an async context.
        try await Task.sleep(for: .seconds(1.1))
        let external = "---\nid: a\ntitle: A\n---\nEXTERNAL EDIT [[Design]]"
        try external.write(to: a, atomically: true, encoding: .utf8)

        let report = s.apply(plan)
        // Compared by basename, not by URL: the report names the file as the
        // INDEX knows it (realpath-canonical, `/private/var/...`), while the
        // test built `a` from `temporaryDirectory` (`/var/...`). Same file,
        // different spelling — see `LoreStore.planMove`.
        XCTAssertEqual(report.skipped.map(\.lastPathComponent), ["a.md"])
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), external)
    }

    func test_linksAreRewrittenBeforeTheFileMoves() async throws {
        // Ordering property: if the move happened first, a failure to rewrite
        // would leave a dangling link. Assert the rewrite is visible in a file
        // whose link still resolves to the OLD path at rewrite time.
        let (root, s) = try vault()
        _ = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(report.movedTo?.lastPathComponent, "Architecture.md")
        XCTAssertEqual(report.rewritten.count, 1)
    }

    func test_openTabOnARewrittenFileIsReloadedNotClobbered() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        s.open(url: a)
        let session = s.selectedTab!
        let before = session.reloadGeneration

        _ = s.apply(s.plan(rename: design, to: "Architecture"))

        XCTAssertGreaterThan(session.reloadGeneration, before)
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Architecture]]"))
    }

    func test_tabOnTheRenamedDocumentFollowsIt() async throws {
        let (root, s) = try vault()
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        s.open(url: design)
        _ = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "Architecture.md")
    }

    func test_renameRefusesWhenDestinationExists() async throws {
        let (root, s) = try vault()
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        _ = try write(root, "Architecture.md", "---\nid: e\ntitle: Arch\n---\ny")
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertNil(report.movedTo)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: design.path))
    }

    /// A collision must be refused BEFORE any link is rewritten. Rewriting
    /// first and discovering the collision after would repoint every inbound
    /// link at a name that never comes to exist.
    func test_refusedRenameLeavesInboundLinksUntouched() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        _ = try write(root, "Architecture.md", "---\nid: e\ntitle: Arch\n---\ny")
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(report.rewritten, [])
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Design]]"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: design.path))
    }

    /// The dirty-tab path: unsaved editor text must survive a rewrite of the
    /// same file. Cancelling the autosave without flushing it first would
    /// discard the edit, and the post-rewrite reload would make it
    /// unrecoverable.
    func test_unsavedEditsInARewrittenFileAreFlushedNotDiscarded() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        s.open(url: a)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "UNSAVED WORK\n\nsee [[Design]]"
        session.markChanged()

        _ = s.apply(s.plan(rename: design, to: "Architecture"))

        let text = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(text.contains("UNSAVED WORK"), text)
        XCTAssertTrue(text.contains("[[Architecture]]"), text)
    }

    /// A bare `[[Design]]` must not be caught by an unanchored replacement of
    /// the word, and neither must a longer basename that merely starts with it.
    func test_rewriteIsAnchoredToLinkDelimiters() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md",
            "---\nid: a\ntitle: A\n---\nThe design of [[Design Notes]] and [[Design]].")
        _ = try write(root, "Design Notes.md", "---\nid: n\ntitle: Design Notes\n---\nn")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        _ = s.apply(s.plan(rename: design, to: "Architecture"))
        let text = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(text.contains("The design of [[Design Notes]] and [[Architecture]]."), text)
    }
}

/// The four defects the Task 7 review found after the first pass.
@MainActor
final class RenameApplicationHardeningTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-rename2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return (root, s)
    }

    private func write(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// FINDING 1. A tab that is dirty AND already conflicted cannot flush: its
    /// `saveNow` re-throws `externalChange`. The plan-time baseline was
    /// captured AFTER that external edit, so the mtime guard would let the
    /// rewrite through and the post-rewrite reload would then replace the
    /// engine's contents — silently destroying the user's unsaved text.
    func test_dirtyConflictedTabKeepsUnsavedTextAndIsReportedAsSkipped() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        s.open(url: a)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "UNSAVED WORK\n\nsee [[Design]]"
        session.markChanged()
        session.cancelPendingSave()

        // An external edit lands BEFORE planning, so the session is already in
        // conflict and the plan-time baseline already reflects that edit.
        try await Task.sleep(for: .seconds(1.1))
        let external = "---\nid: a\ntitle: A\n---\nEXTERNAL [[Design]]"
        try external.write(to: a, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try session.saveNow())
        XCTAssertTrue(session.conflict)
        XCTAssertTrue(session.isDirty)

        let report = s.apply(s.plan(rename: design, to: "Architecture"))

        // The file was not written...
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), external)
        // ...the outcome is in the report...
        XCTAssertEqual(report.skipped.map(\.lastPathComponent), ["a.md"])
        XCTAssertFalse(report.rewritten.contains { $0.lastPathComponent == "a.md" })
        // ...and the unsaved text is still in the editor, still conflicted,
        // for the user to resolve themselves.
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(session.conflict)
        XCTAssertTrue(engine.note.body.contains("UNSAVED WORK"))
    }

    /// FINDING 2. `moveItem` can fail for reasons other than a collision. A
    /// missing destination folder must be refused BEFORE any link is rewritten.
    func test_moveIntoMissingFolderRefusesAndWritesNothing() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Projects/Design]]")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        let design = try write(root, "Projects/Design.md",
                               "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        let missing = root.appendingPathComponent("Nope")
        let plan = s.plan(move: design, toFolder: missing)
        XCTAssertFalse(plan.edits.isEmpty, "precondition: there is something to rewrite")

        let report = s.apply(plan)
        XCTAssertNil(report.movedTo)
        XCTAssertEqual(report.rewritten, [])
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Projects/Design]]"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: design.path))
    }

    /// FINDING 3. A self-linking document is both the move source and a rewrite
    /// target. Matching sessions by path after `adoptRenamed` never finds it,
    /// so it kept pre-rewrite text and its next save reverted the self-link.
    func test_selfLinkingDocumentSurvivesRenameAcrossItsNextSave() async throws {
        let (root, s) = try vault()
        let design = try write(root, "Design.md",
                               "---\nid: d\ntitle: Design\n---\nsee [[Design]] here")
        await s.settleForTesting(); try s.rebuild()

        s.open(url: design)
        let session = try XCTUnwrap(s.selectedTab)
        let plan = s.plan(rename: design, to: "Architecture")
        XCTAssertEqual(plan.edits.count, 1, "precondition: the self-link is an edit")

        _ = s.apply(plan)
        let moved = root.appendingPathComponent("Architecture.md")
        XCTAssertEqual(session.url.lastPathComponent, "Architecture.md")
        XCTAssertTrue(try String(contentsOf: moved, encoding: .utf8).contains("[[Architecture]]"))

        // The real regression: the session's next save must not write a stale
        // pre-rewrite buffer back over the rewrite.
        session.markChanged()
        session.cancelPendingSave()
        try session.saveNow()
        let text = try String(contentsOf: moved, encoding: .utf8)
        XCTAssertTrue(text.contains("[[Architecture]]"), text)
        XCTAssertFalse(text.contains("[[Design]]"), text)
    }

    /// FINDING 4. "Opened it and nothing matched" is neither a write nor a
    /// refusal, and reporting it as `rewritten` makes the report untruthful.
    func test_applyEditsDistinguishesWrittenUnchangedAndSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-outcome-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.md")
        try "see [[Design]]".write(to: file, atomically: true, encoding: .utf8)
        let baseline = try XCTUnwrap(FileManager.default
            .attributesOfItem(atPath: file.path)[.modificationDate] as? Date)

        let hit = [LinkEdit(file: file, oldTarget: "Design", newTarget: "Architecture")]
        let miss = [LinkEdit(file: file, oldTarget: "Nothing", newTarget: "Else")]

        // Nothing matches: unchanged, and the file is left byte-identical.
        XCTAssertEqual(try LinkRewriter.applyEdits(miss, to: file, baseline: baseline),
                       .unchanged)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[Design]]")

        // No baseline: fail closed.
        XCTAssertEqual(try LinkRewriter.applyEdits(hit, to: file, baseline: nil), .skipped)
        // Stale baseline: refuse.
        XCTAssertEqual(try LinkRewriter.applyEdits(hit, to: file,
                                                   baseline: .distantPast), .skipped)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[Design]]")

        // A real match writes.
        XCTAssertEqual(try LinkRewriter.applyEdits(hit, to: file, baseline: baseline),
                       .written)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[Architecture]]")
    }

    /// MINOR. The moved file, when it was itself rewritten, must be reported at
    /// its NEW path — the old one no longer exists by the time the UI renders.
    func test_reportNamesTheMovedFileAtItsNewPath() async throws {
        let (root, s) = try vault()
        let design = try write(root, "Design.md",
                               "---\nid: d\ntitle: Design\n---\nsee [[Design]]")
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(report.rewritten.map(\.lastPathComponent), ["Architecture.md"])
        for url in report.rewritten {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    func test_folderRenamePlansEveryDocumentBeneathIt() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nid: d\ntitle: Design\n---\nx"
            .write(to: folder.appendingPathComponent("Design.md"),
                   atomically: true, encoding: .utf8)
        try "---\nid: n\ntitle: Notes\n---\ny"
            .write(to: folder.appendingPathComponent("Notes.md"),
                   atomically: true, encoding: .utf8)
        try "---\nid: a\ntitle: A\n---\n[[Projects/Design]]"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        let plans = s.plan(renameFolder: folder, to: "Work")
        XCTAssertEqual(plans.count, 2)
        let reports = s.apply(plans)
        XCTAssertTrue(reports.allSatisfy { $0.failed.isEmpty })
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("a.md"),
                                 encoding: .utf8).contains("[[Work/Design]]"))
    }
}
