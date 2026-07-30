import XCTest
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

final class LinkCompletionTests: XCTestCase {
    func test_detectsPrefixAfterOpenBrackets() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "see [[Des", caret: 9), "Des")
    }

    func test_returnsEmptyPrefixImmediatelyAfterBrackets() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "see [[", caret: 6), "")
    }

    func test_nilWhenLinkIsAlreadyClosed() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "see [[Design]] x", caret: 16))
    }

    func test_nilWhenNoBracketsBeforeCaret() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "plain text", caret: 5))
    }

    func test_stopsAtNewline() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "[[\nDesign", caret: 9))
    }

    func test_usesTheNearestOpenBrackets() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "[[A]] and [[B", caret: 13), "B")
    }

    /// The index-based rewrite must keep working on multi-scalar characters,
    /// where a Character offset and a UTF-16 offset disagree.
    func test_prefixWithMultiScalarCharacters() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "[[👍a", caret: 4), "👍a")
    }

    func test_prefixIgnoresAnOutOfRangeCaret() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "[[A", caret: 99))
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "[[A", caret: -1))
    }

    // MARK: - Click-to-open span detection

    func test_targetUnderCaretInsideSpan() {
        XCTAssertEqual(LinkCompletionContext.target(in: "see [[Design]] x", at: 8), "Design")
    }

    func test_targetAtSpanEdges() {
        // Just inside the opening brackets and just before the closing ones.
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 2), "Design")
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 8), "Design")
    }

    /// The brackets are part of the link as far as the user is concerned, so
    /// clicking them opens it too.
    func test_targetOnTheBracketGlyphsThemselves() {
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 0), "Design")
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 1), "Design")
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 9), "Design")
        XCTAssertEqual(LinkCompletionContext.target(in: "x [[Design]] y", at: 2), "Design")
    }

    func test_targetNilOutsideAnySpan() {
        XCTAssertNil(LinkCompletionContext.target(in: "see [[Design]] x", at: 15))
        XCTAssertNil(LinkCompletionContext.target(in: "plain text", at: 3))
    }

    func test_targetDoesNotCrossLines() {
        XCTAssertNil(LinkCompletionContext.target(in: "[[Design\n]] x", at: 4))
    }

    func test_targetKeepsRawAliasAndHeadingSyntax() {
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design#Goals|why]]", at: 5),
                       "Design#Goals|why")
    }

    func test_targetNilForEmptySpan() {
        XCTAssertNil(LinkCompletionContext.target(in: "[[]]", at: 2))
    }

    // MARK: - documentName

    func test_documentNameStripsAliasAndFragment() {
        XCTAssertEqual(LinkCompletionContext.documentName(of: "Design#Goals|why"), "Design")
        XCTAssertEqual(LinkCompletionContext.documentName(of: "Design|why"), "Design")
        XCTAssertEqual(LinkCompletionContext.documentName(of: "Design#Goals"), "Design")
        XCTAssertEqual(LinkCompletionContext.documentName(of: "Projects/Design"),
                       "Projects/Design")
    }

    // MARK: - Selection state

    private func rows(_ n: Int) -> [IndexRow] {
        (0..<n).map { i in
            IndexRow(path: URL(fileURLWithPath: "/v/\(i).md"), id: "\(i)", title: "T\(i)",
                     tags: [], aliases: [], updated: Date(), type: "markdown", properties: [])
        }
    }

    func test_selectionStartsAtTheTop() {
        let three = rows(3)
        var s = LinkCompletionSelection()
        s.update(to: three)
        XCTAssertEqual(s.index, 0)
        XCTAssertEqual(s.current, three[0])
    }

    func test_selectionClampsAtBothEnds() {
        var s = LinkCompletionSelection()
        s.update(to: rows(3))
        s.move(by: -1)
        XCTAssertEqual(s.index, 0, "up at the top must not wrap to the bottom")
        s.move(by: 5)
        XCTAssertEqual(s.index, 2, "down past the end must not wrap to the top")
    }

    /// The highlight may never point past a row the list can actually show.
    func test_selectionClampsToTheVisibleRowLimit() {
        var s = LinkCompletionSelection()
        s.update(to: rows(20))
        s.move(by: 50)
        XCTAssertEqual(s.index, LinkCompletionView.maxRows - 1)
        XCTAssertEqual(s.visibleCount, LinkCompletionView.maxRows)
    }

    func test_changedMatchesResetTheHighlight() {
        let five = rows(5)
        var s = LinkCompletionSelection()
        s.update(to: five)
        s.move(by: 3)
        XCTAssertEqual(s.index, 3)
        s.update(to: Array(five.dropFirst()))
        XCTAssertEqual(s.index, 0, "a different match set must not keep the old highlight")
    }

    func test_identicalMatchesKeepTheHighlight() {
        let five = rows(5)
        var s = LinkCompletionSelection()
        s.update(to: five)
        s.move(by: 2)
        s.update(to: five)
        XCTAssertEqual(s.index, 2)
    }

    func test_emptySelectionHasNoCurrentRow() {
        var s = LinkCompletionSelection()
        s.update(to: rows(3))
        s.move(by: 2)
        s.clear()
        XCTAssertNil(s.current)
        XCTAssertEqual(s.index, 0)
        s.move(by: 1)
        XCTAssertEqual(s.index, 0, "moving with no matches must stay put")
    }

    // MARK: - View smoke test

    func test_completionViewBuilds() {
        _ = LinkCompletionView(matches: rows(12), selected: 3,
                               tokens: TestTokens.make()) { _ in }
        _ = LinkCompletionView(matches: [], selected: 0,
                               tokens: TestTokens.make()) { _ in }
    }
}

/// What a picked completion inserts has to resolve back to the document that
/// was picked. These go through the real `LinkResolver` on a real vault,
/// because the assertion that matters is "resolving the inserted text finds
/// this file again", not the literal string.
@MainActor
final class LinkInsertionRoundTripTests: XCTestCase {
    private func vault(_ files: [(name: String, title: String)]) async throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-insert-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            // Quoted: these titles contain YAML-significant characters.
            try "---\nid: \(file.name)\ntitle: \"\(file.title)\"\n---\nbody"
                .write(to: root.appendingPathComponent("\(file.name).md"),
                       atomically: true, encoding: .utf8)
        }
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        // Activation scans in the background; the rows are not there until it lands.
        await store.settleForTesting()
        return (root, store)
    }

    private func assertRoundTrip(name: String, title: String,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let (root, store) = try await vault([(name, title)])
        guard let row = store.rows.first(where: { $0.path.lastPathComponent == "\(name).md" })
        else { return XCTFail("row not indexed", file: file, line: line) }
        let inserted = LinkCompletionContext.insertableTarget(for: row)
        XCTAssertEqual(store.resolveLink(inserted)?.lastPathComponent, "\(name).md",
                       "[[\(inserted)]] must find \(name).md again", file: file, line: line)
        XCTAssertEqual(store.resolveLink(inserted)?.deletingLastPathComponent().lastPathComponent,
                       root.lastPathComponent, file: file, line: line)
    }

    func test_plainTitleRoundTrips() async throws {
        try await assertRoundTrip(name: "design", title: "Design")
    }

    /// `#` starts a fragment — `[[Sprint #3]]` resolves to "Sprint", or nothing.
    func test_titleWithHashRoundTrips() async throws {
        try await assertRoundTrip(name: "sprint-3", title: "Sprint #3")
    }

    /// `|` starts an alias.
    func test_titleWithPipeRoundTrips() async throws {
        try await assertRoundTrip(name: "either-or", title: "Either|Or")
    }

    /// `]]` would truncate the span outright.
    func test_titleWithClosingBracketsRoundTrips() async throws {
        try await assertRoundTrip(name: "brackets", title: "Odd]]Title")
    }

    func test_titleWithOpeningBracketsRoundTrips() async throws {
        try await assertRoundTrip(name: "opening", title: "Odd[[Title")
    }

    /// A `/` in a title would be read as a path suffix, which this file is not.
    func test_titleWithSlashRoundTrips() async throws {
        try await assertRoundTrip(name: "ratio", title: "A/B Test")
    }

    /// `basename` strips a trailing `.md`.
    func test_titleEndingInDotMDRoundTrips() async throws {
        try await assertRoundTrip(name: "readme-doc", title: "Readme.md")
    }

    func test_emptyTitleFallsBackToTheFilename() async throws {
        try await assertRoundTrip(name: "untitled-note", title: "")
    }

    /// The usable case must still prefer the human title over the slug.
    func test_usableTitleIsPreferredOverTheFilename() async throws {
        let (_, store) = try await vault([("design-doc", "Design")])
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(LinkCompletionContext.insertableTarget(for: row), "Design")
    }
}

/// The "this link points nowhere — create it?" path.
@MainActor
final class LinkCreateOnUnresolvedTests: XCTestCase {
    private func store() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-create-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store)
    }

    /// `[[Projects/Design]]` used to fail silently: `create` slugged the whole
    /// thing to `projects/design` and wrote into a folder that did not exist.
    func test_createsTheSubfolderNamedByTheLink() throws {
        let (root, store) = try store()
        let note = try store.create(title: "Design", in: "Projects")
        XCTAssertEqual(note.path.deletingLastPathComponent().lastPathComponent, "Projects")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path.path))
        XCTAssertTrue(note.path.resolvingSymlinksInPath().path
            .hasPrefix(root.resolvingSymlinksInPath().path))
        // The whole point: the link the user clicked now resolves.
        XCTAssertEqual(store.resolveLink("Projects/Design"), note.path)
    }

    func test_createsNestedSubfolders() throws {
        let (_, store) = try store()
        let note = try store.create(title: "Design", in: "A/B")
        XCTAssertEqual(store.resolveLink("A/B/Design"), note.path)
    }

    /// The folder name is untrusted document text.
    func test_subfolderCannotEscapeTheVault() throws {
        let (root, store) = try store()
        let note = try store.create(title: "Design", in: "../../etc")
        XCTAssertTrue(note.path.resolvingSymlinksInPath().path
            .hasPrefix(root.resolvingSymlinksInPath().path),
                      "a link must never write outside the vault: \(note.path.path)")
    }

    /// `[[Design|why]]` names the document "Design", not "Design|why".
    func test_aliasIsNotPartOfTheCreatedNoteName() throws {
        let (_, store) = try store()
        let name = LinkCompletionContext.documentName(of: "Design|why")
        XCTAssertEqual(name, "Design")
        let note = try store.create(title: name)
        XCTAssertEqual(note.title, "Design")
        XCTAssertEqual(store.resolveLink("Design"), note.path)
    }

    /// Failure must be reportable, not swallowed — `create` throws rather than
    /// returning nil, which is what lets `DocumentPane` surface it.
    func test_createThrowsWithoutAVault() {
        let store = LoreStore(documents: FakeDocs(),
            indexPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID()).sqlite"))
        XCTAssertThrowsError(try store.create(title: "Design"))
    }
}
