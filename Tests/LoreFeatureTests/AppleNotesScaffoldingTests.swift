import XCTest
import GRDB
@testable import LoreFeature

/// Tasks 2, 3, 4 and 7 — the parts of the Apple Notes reader that need no Full
/// Disk Access grant, because none of them touch the real store. The locator is
/// pointed at a temp home, the snapshot copies files these tests wrote, the
/// schema check runs against databases built here, and the AppleScript source
/// is driven through an injected runner.
///
/// A test must never read the user's real `NoteStore.sqlite` or launch
/// Notes.app: it would depend on the contents of one particular note library
/// and prompt for a TCC grant in the middle of a suite run.
final class NotesStoreLocatorTests: XCTestCase {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func makeContainer(in home: URL) throws -> URL {
        let container = home.appendingPathComponent(NotesStoreLocator.containerPath)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    func testReportsNotPresentWhenTheContainerIsMissing() throws {
        XCTAssertEqual(NotesStoreLocator.probe(home: try makeHome()), .notPresent)
    }

    func testReportsAvailableWhenTheStoreExists() throws {
        let home = try makeHome()
        let store = try makeContainer(in: home)
            .appendingPathComponent(NotesStoreLocator.storeName)
        try Data().write(to: store)
        XCTAssertEqual(NotesStoreLocator.probe(home: home), .available(store))
    }

    /// A container that exists but holds no store is `.notPresent`, NOT
    /// `.permissionDenied` — offering a Full Disk Access prompt to a user who
    /// has simply never used Notes sends them to System Settings to fix
    /// nothing.
    func testAnEmptyContainerIsNotAPermissionProblem() throws {
        let home = try makeHome()
        _ = try makeContainer(in: home)
        XCTAssertEqual(NotesStoreLocator.probe(home: home), .notPresent)
    }

    /// The distinction the whole type exists for. TCC denial presents as a
    /// directory that exists and cannot be listed, which is what stripping
    /// every permission bit reproduces.
    func testAnUnlistableContainerIsAPermissionProblem() throws {
        let home = try makeHome()
        let container = try makeContainer(in: home)
        try Data().write(to: container.appendingPathComponent(NotesStoreLocator.storeName))
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: container.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: container.path)
        }
        try XCTSkipIf(getuid() == 0, "root bypasses POSIX permissions entirely")
        XCTAssertEqual(NotesStoreLocator.probe(home: home), .permissionDenied)
    }
}

final class NotesStoreSnapshotTests: XCTestCase {
    private func makeStore(sidecars: Bool = true) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("NoteStore.sqlite")
        try Data("main".utf8).write(to: store)
        if sidecars {
            try Data("wal".utf8).write(to: dir.appendingPathComponent("NoteStore.sqlite-wal"))
            try Data("shm".utf8).write(to: dir.appendingPathComponent("NoteStore.sqlite-shm"))
        }
        return store
    }

    /// The `-wal` sidecar carries committed writes the main file does not.
    /// Copying without it yields a database missing the user's most recent
    /// notes — presenting as a SUCCESSFUL import that quietly lost them.
    func testCopiesTheWALSidecarsAlongsideTheDatabase() throws {
        let snapshot = try NotesStoreSnapshot(copying: try makeStore())
        let dir = snapshot.url.deletingLastPathComponent()
        XCTAssertEqual(try Data(contentsOf: snapshot.url), Data("main".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("NoteStore.sqlite-wal")),
                       Data("wal".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("NoteStore.sqlite-shm")),
                       Data("shm".utf8))
    }

    /// A cleanly checkpointed store has no `-wal` at all. Requiring one would
    /// refuse to read a perfectly good database.
    func testSucceedsWhenTheSidecarsAreAbsent() throws {
        let store = try makeStore(sidecars: false)
        let snapshot = try NotesStoreSnapshot(copying: store)
        XCTAssertEqual(try Data(contentsOf: snapshot.url), Data("main".utf8))
    }

    func testCopiesSomewhereOtherThanTheOriginal() throws {
        let store = try makeStore()
        let snapshot = try NotesStoreSnapshot(copying: store)
        XCTAssertNotEqual(snapshot.url.path, store.path)
    }

    func testRemovesTheCopyWhenReleased() throws {
        var snapshot: NotesStoreSnapshot? = try NotesStoreSnapshot(copying: try makeStore())
        let copied = snapshot!.url
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
    }
}

final class NotesSchemaTests: XCTestCase {
    private func makeDB(_ setup: (Database) throws -> Void) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { try setup($0) }
        return queue
    }

    private func createFullSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE ZICNOTEDATA (Z_PK INTEGER, ZNOTE INTEGER, ZDATA BLOB);
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                Z_PK INTEGER, ZTITLE1 TEXT, ZIDENTIFIER TEXT, ZFOLDER INTEGER,
                ZCREATIONDATE1 REAL, ZMODIFICATIONDATE1 REAL, ZMARKEDFORDELETION INTEGER);
            """)
    }

    func testAcceptsAStoreWithEveryRequiredColumn() throws {
        XCTAssertEqual(try NotesSchema.check(try makeDB(createFullSchema)), .supported)
    }

    func testRejectsAStoreMissingTheBodyTable() throws {
        let db = try makeDB { db in
            try db.execute(sql: "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER)")
        }
        guard case .unsupported(let missing) = try NotesSchema.check(db) else {
            return XCTFail("expected .unsupported")
        }
        XCTAssertTrue(missing.contains("ZICNOTEDATA"), "got \(missing)")
    }

    /// The realistic OS-update failure: not a table vanishing, but one column
    /// being renamed. This is the case that would otherwise yield notes with
    /// silently empty bodies.
    func testRejectsAStoreMissingASingleRequiredColumn() throws {
        let db = try makeDB { db in
            try createFullSchema(db)
            try db.execute(sql: "ALTER TABLE ZICNOTEDATA DROP COLUMN ZDATA")
        }
        guard case .unsupported(let missing) = try NotesSchema.check(db) else {
            return XCTFail("expected .unsupported")
        }
        XCTAssertEqual(missing, ["ZICNOTEDATA.ZDATA"])
    }

    /// A table missing entirely is reported ONCE, not as one entry per column
    /// it would have had — a diagnostic buried in noise is a diagnostic nobody
    /// reads.
    func testAMissingTableIsReportedOnceNotPerColumn() throws {
        let db = try makeDB { db in
            try db.execute(sql: "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER, ZNOTE INTEGER, ZDATA BLOB)")
        }
        guard case .unsupported(let missing) = try NotesSchema.check(db) else {
            return XCTFail("expected .unsupported")
        }
        XCTAssertEqual(missing, ["ZICCLOUDSYNCINGOBJECT"])
    }
}

final class AppleNotesScriptSourceTests: XCTestCase {
    private struct StubRunner: ScriptRunner {
        let output: String
        func run(_ source: String) throws -> String { output }
    }

    private struct DenyingRunner: ScriptRunner {
        func run(_ source: String) throws -> String {
            throw ImportSourceError.permissionDenied("Automation not allowed")
        }
    }

    /// Two records. Dates are seconds since the Unix epoch, which is what the
    /// script emits — deliberately not a localised date string.
    private let canned = """
    x-coredata://N1
    Groceries
    Shopping
    978307200
    978307300
    <p>milk</p>
    \u{1E}
    x-coredata://N2
    Ideas
    Notes
    978307200
    978307300
    <p>a <b>bold</b> plan</p>
    """

    func testParsesEveryRecord() {
        let items = AppleNotesScriptSource.parse(canned)
        XCTAssertEqual(items.map(\.title), ["Groceries", "Ideas"])
        XCTAssertEqual(items[0].sourceID, "apple-notes:x-coredata://N1")
        XCTAssertEqual(items[0].folderPath, ["Shopping"])
        XCTAssertEqual(items[0].created, Date(timeIntervalSince1970: 978307200))
        guard case .html(let raw) = items[1].body else { return XCTFail("expected .html") }
        XCTAssertTrue(raw.contains("<b>bold</b>"))
    }

    /// A note from this source is always a `.note`, never a `.file` — an Apple
    /// note that is just a photo with a title is ordinary, and must keep its
    /// title and dates. See `ImportItemKind`.
    func testEveryScriptedNoteIsANoteNotAFile() {
        XCTAssertTrue(AppleNotesScriptSource.parse(canned).allSatisfy { $0.kind == .note })
    }

    func testAMultiLineBodyIsKeptWhole() {
        let items = AppleNotesScriptSource.parse("""
        x-coredata://N1
        Long
        Notes
        0
        0
        <p>one</p>
        <p>two</p>
        """)
        guard case .html(let raw) = items[0].body else { return XCTFail("expected .html") }
        XCTAssertEqual(raw, "<p>one</p>\n<p>two</p>")
    }

    func testIgnoresATrailingRecordSeparator() {
        XCTAssertEqual(AppleNotesScriptSource.parse(canned + "\n\u{1E}\n").count, 2)
    }

    /// Padding a truncated record would import a note with a fabricated title
    /// or date. Dropping it loses one note from a run the user can repeat.
    func testDropsATruncatedRecordRatherThanGuessingAtItsFields() {
        XCTAssertTrue(AppleNotesScriptSource.parse("x-coredata://N1\nJust a title").isEmpty)
    }

    /// An Automation denial is a DIFFERENT grant from Full Disk Access, and
    /// must surface as its own actionable state rather than a generic failure.
    func testScanSurfacesAutomationDenialAsPermissionDenied() async {
        do {
            _ = try await AppleNotesScriptSource(runner: DenyingRunner()).scan()
            XCTFail("expected .permissionDenied")
        } catch let error as ImportSourceError {
            guard case .permissionDenied = error else {
                return XCTFail("expected .permissionDenied, got \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testScanRunsTheScriptThroughTheInjectedRunner() async throws {
        let items = try await AppleNotesScriptSource(runner: StubRunner(output: canned)).scan()
        XCTAssertEqual(items.count, 2)
    }
}
