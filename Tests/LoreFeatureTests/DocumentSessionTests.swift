import XCTest
@testable import LoreFeature

@MainActor
final class DocumentSessionTests: XCTestCase {
    private func vault() throws -> (URL, VaultIndexCoordinator) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-sess-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let c = VaultIndexCoordinator(indexPath: root.appendingPathComponent(".idx.sqlite"))
        try c.activate(root: root)
        return (root, c)
    }

    private func note(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_markChanged_setsDirty() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertFalse(s.isDirty)
        s.markChanged()
        XCTAssertTrue(s.isDirty)
    }

    func test_saveNow_clearsDirtyAndWritesFile() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "changed body"
        s.markChanged()
        try s.saveNow()
        XCTAssertFalse(s.isDirty)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("changed body"))
    }

    func test_title_comesFromEngineAndRefreshesOnSave() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertEqual(s.title, "T")
        (s.engine as! MarkdownEngine).note.title = "T2"
        try s.saveNow()
        XCTAssertEqual(s.title, "T2")
    }

    func test_externalChange_blocksSaveAndFlagsConflict() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        Thread.sleep(forTimeInterval: 1.1)   // exceed filesystem mtime granularity
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        XCTAssertTrue(s.conflict)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("EXTERNAL"))
    }

    func test_resolveByOverwriting_writesOurVersion() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "ours"
        Thread.sleep(forTimeInterval: 1.1)
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        try s.resolveByOverwriting()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("ours"))
        XCTAssertFalse(s.conflict)
    }

    func test_resolveBySavingCopy_leavesOriginalIntact() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "ours"
        Thread.sleep(forTimeInterval: 1.1)
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        let copy = try s.resolveBySavingCopy()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("EXTERNAL"))
        XCTAssertTrue(try String(contentsOf: copy, encoding: .utf8).contains("ours"))
    }

    func test_resolveByReloading_discardsOurEdits() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "ours"
        Thread.sleep(forTimeInterval: 1.1)
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        try s.resolveByReloading()
        XCTAssertFalse(s.conflict)
        XCTAssertFalse(s.isDirty)
        XCTAssertTrue((s.engine as! MarkdownEngine).note.body.contains("EXTERNAL"))
    }

    /// Ruling 2: the editors seed `@State` in `.onAppear`, so a reload that
    /// mutates the engine in place needs a signal the view can key its `.id()`
    /// off, or the user sees the old text after clicking Reload.
    func test_resolveByReloading_bumpsReloadGeneration() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertEqual(s.reloadGeneration, 0)
        try s.resolveByReloading()
        XCTAssertEqual(s.reloadGeneration, 1)
        try s.resolveByReloading()
        XCTAssertEqual(s.reloadGeneration, 2)
    }

    // MARK: - Ruling 1: read-only (lossily decoded) documents

    /// A `.txt` whose bytes are not valid UTF-8, so `PlainTextEngine.load`
    /// falls back to a lossy decode and `save` refuses to write it.
    private func lossyFile(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("bad.txt")
        try Data([0x68, 0x69, 0xFF, 0xFE, 0x0A]).write(to: url)
        return url
    }

    func test_lossilyDecodedDocument_isReadOnly() throws {
        let (root, c) = try vault()
        let s = try DocumentSession.open(url: try lossyFile(root), coordinator: c)
        XCTAssertTrue(s.isReadOnly)
        let ok = try DocumentSession.open(
            url: try note(root, "fine.txt", "hello"), coordinator: c)
        XCTAssertFalse(ok.isReadOnly)
    }

    func test_readOnlySession_saveNowThrowsNotRoundTrippable() throws {
        let (root, c) = try vault()
        let url = try lossyFile(root)
        let s = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertThrowsError(try s.saveNow()) { error in
            XCTAssertEqual(error as? EngineError, .notRoundTrippable(url))
        }
    }

    func test_readOnlySession_markChangedDoesNotAutosave() async throws {
        let (root, c) = try vault()
        let url = try lossyFile(root)
        let before = try Data(contentsOf: url)
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! PlainTextEngine).text = "clobbered"
        s.markChanged()
        XCTAssertTrue(s.isDirty)
        // Well past the 500ms autosave debounce.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
