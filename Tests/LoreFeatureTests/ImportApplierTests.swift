import XCTest
@testable import LoreFeature

@MainActor
final class ImportApplierTests: XCTestCase {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func item(_ id: String, _ title: String,
                      body: ImportBody = .markdown("hello")) -> ImportItem {
        ImportItem(sourceID: id, title: title, body: body, attachments: [],
                   folderPath: [], created: Date(), modified: Date(), fidelity: [])
    }

    func testWritesTheNoteWithItsImportIDInFrontmatter() async throws {
        let vault = try makeVault()
        let plan = ImportPlanner.plan(items: [item("apple-notes:N1", "Plan")],
                                      vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        XCTAssertEqual(report.imported.count, 1)
        let text = try String(contentsOf: report.imported[0], encoding: .utf8)
        XCTAssertTrue(text.contains("lore_import_id: apple-notes:N1"))
        XCTAssertTrue(text.contains("hello"))
    }

    func testConvertsHTMLBodiesAndKeepsTheOriginalBeside() async throws {
        let vault = try makeVault()
        let plan = ImportPlanner.plan(
            items: [item("apple-notes:N2", "Bold", body: .html("<p>a <b>b</b></p>"))],
            vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        let text = try String(contentsOf: report.imported[0], encoding: .utf8)
        XCTAssertTrue(text.contains("a **b**"))
        let original = vault.appendingPathComponent("Bold.original.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testSkipsAlreadyImportedItemsWithoutWriting() async throws {
        let vault = try makeVault()
        let plan = ImportPlanner.plan(items: [item("apple-notes:N1", "Plan")],
                                      vaultRoot: vault,
                                      existingImportIDs: ["apple-notes:N1"])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        XCTAssertTrue(report.imported.isEmpty)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Plan.md").path))
    }

    func testASecondApplyOfTheSameSourceCreatesNothing() async throws {
        let vault = try makeVault()
        let items = [item("apple-notes:N1", "Plan")]
        let applier = ImportApplier(vaultRoot: vault)
        _ = await applier.apply(ImportPlanner.plan(items: items, vaultRoot: vault,
                                                   existingImportIDs: []))
        let before = try FileManager.default.contentsOfDirectory(atPath: vault.path).count
        // The second run is planned with the IDs the first run wrote — exactly what
        // the UI does by reading them back off disk.
        let second = await applier.apply(ImportPlanner.plan(
            items: items, vaultRoot: vault, existingImportIDs: ["apple-notes:N1"]))
        XCTAssertTrue(second.imported.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path).count,
                       before)
    }

    func testOneFailedItemDoesNotAbortTheRun() async throws {
        let vault = try makeVault()
        let good = item("apple-notes:N1", "Good")
        let bad = ImportItem(sourceID: "apple-notes:N2", title: "Bad",
                             body: .markdown("x"),
                             attachments: [ImportAttachment(
                                sourceID: "a", preferredName: "missing.png",
                                sourceURL: URL(fileURLWithPath: "/nope/missing.png"))],
                             folderPath: [], created: Date(), modified: Date(),
                             fidelity: [])
        let plan = ImportPlanner.plan(items: [bad, good], vaultRoot: vault,
                                      existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        XCTAssertEqual(report.imported.count, 2)   // the note still lands
        XCTAssertEqual(report.failed.count, 1)     // its attachment is reported
    }

    /// Beyond the brief: an on-disk file the user already owns — never
    /// produced by this selection, so the planner (which only dedups WITHIN
    /// a selection) cannot know about it — must never be overwritten.
    func testOnDiskCollisionWithAUserOwnedFileIsRenamedNotOverwritten() async throws {
        let vault = try makeVault()
        let existing = vault.appendingPathComponent("Plan.md")
        try "user's own note".write(to: existing, atomically: true, encoding: .utf8)

        let plan = ImportPlanner.plan(items: [item("apple-notes:N1", "Plan")],
                                      vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)

        XCTAssertEqual(report.imported.count, 1)
        XCTAssertNotEqual(report.imported[0], existing)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "user's own note")
        let importedText = try String(contentsOf: report.imported[0], encoding: .utf8)
        XCTAssertTrue(importedText.contains("lore_import_id: apple-notes:N1"))
    }

    /// A title with YAML-hostile characters must still produce a file whose
    /// frontmatter `Frontmatter.parse` reads back correctly — string
    /// interpolation would instead emit invalid YAML.
    func testTitleWithColonAndLeadingDashRoundTripsThroughFrontmatterParse() async throws {
        let vault = try makeVault()
        let plan = ImportPlanner.plan(
            items: [item("apple-notes:N3", "-Meeting: Q3\nfollow-up")],
            vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        XCTAssertEqual(report.imported.count, 1)

        let text = try String(contentsOf: report.imported[0], encoding: .utf8)
        let note = Frontmatter.parse(text, path: report.imported[0])
        XCTAssertEqual(note.title, "-Meeting: Q3\nfollow-up")
        XCTAssertTrue(note.extra.contains { $0.key == "lore_import_id"
            && $0.rawValue == "apple-notes:N3" })
    }
}
