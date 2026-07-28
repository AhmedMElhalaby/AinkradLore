import Testing
import Foundation
import AinkradAppKit
@testable import LoreFeature

private final class MemoryDocs: PluginDocumentStore {
    private var store: [String: Data] = [:]
    func data(forKey key: String) -> Data? { store[key] }
    func setData(_ data: Data?, forKey key: String) { store[key] = data }
}

/// A temp vault. **Never the user's real vault.**
@MainActor
private func makeVault() async throws -> (URL, LoreNoteOperations, LoreStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lore-ops-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = LoreStore(documents: MemoryDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
    try store.setVaultRootForTesting(root)
    // Activation starts a background rescan of the (empty) vault. Let it finish
    // before the test writes anything, or its `replaceAll` can land afterwards
    // and wipe the notes the test just created.
    await store.settleForTesting()
    return (root, LoreNoteOperations(store: store), store)
}

@MainActor
private func run(_ operations: LoreNoteOperations,
                 _ object: [String: Any]) async -> (text: String, isError: Bool) {
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    let result = await operations.run(json)
    return (result.text, result.isError)
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LoreNoteOperationsTests {

    // MARK: - the fresh-install case
    //
    // A store whose bookmark never resolved has no vault. Left unhandled this
    // is the WORST state to debug from the assistant's side, because the
    // underlying APIs disagree about how to fail: `search` returns an empty
    // array, `create`/`save`/`delete` throw `LoreError.noVault`, and
    // `allTags`/`subfolders` return empty arrays. "No notes match" is a lie
    // when the truth is "there is no vault".

    private func vaultlessOperations() -> LoreNoteOperations {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-novault-\(UUID())", isDirectory: true)
        let store = LoreStore(documents: MemoryDocs(),
                              indexPath: root.appendingPathComponent(".index.sqlite"))
        return LoreNoteOperations(store: store)
    }

    /// Walks the WHOLE published table rather than naming operations, so a tool
    /// added later cannot quietly skip the check.
    @Test func everyPublishedOperationFailsClearlyWithNoVault() async {
        let operations = vaultlessOperations()
        for tool in LoreMCPServer.tools {
            let outcome = await run(operations, ["operation": tool.operation, "note": "anything"])
            #expect(outcome.isError, "\(tool.name) did not report an error without a vault")
            #expect(outcome.text == LoreNoteOperations.noVaultMessage,
                    "\(tool.name) gave a confusing message without a vault: \(outcome.text)")
        }
    }

    @Test func theVaultResourceSaysSoWhenThereIsNoVault() {
        #expect(vaultlessOperations().vaultSummary() == LoreNoteOperations.noVaultMessage)
    }

    @Test func theVaultResourceReportsTheRootAndCounts() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Counted")
        note.tags = ["alpha"]
        try store.save(note)

        let summary = operations.vaultSummary()
        #expect(summary.contains(root.path))
        #expect(summary.contains("notes: 1"))
        #expect(summary.contains("tags: 1"))
    }

    // MARK: - read

    @Test func searchFindsNotesByBody() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Findable")
        note.body = "a distinctive haystack"
        try store.save(note)

        let outcome = await run(operations, ["operation": "search", "query": "haystack"])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains(note.id))
        #expect(outcome.text.contains("Findable"))
    }

    @Test func anEmptyQueryListsRecentNotesRatherThanNothing() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(title: "Browseable")

        let outcome = await run(operations, ["operation": "search"])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains("Browseable"))
    }

    @Test func searchReportsNoMatchesWithoutErroring() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "search", "query": "nothingatall"])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains("No notes match"))
    }

    @Test func readReturnsTitleTagsAndBody() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Readable")
        note.tags = ["one", "two"]
        note.body = "the body text"
        try store.save(note)

        let outcome = await run(operations, ["operation": "read", "note": note.id])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains("title: Readable"))
        #expect(outcome.text.contains("tags: one, two"))
        #expect(outcome.text.contains("the body text"))
        // Vault-relative, not the user's absolute home path.
        #expect(outcome.text.contains("path: \(note.path.lastPathComponent)"))
    }

    /// `read_note` is advertised `readOnly`, and that has to be true of the
    /// STORE's state as well as the disk. `LoreStore.load` re-baselines the
    /// external-change mtime, so using it here would disarm the guard that
    /// stops an open editor's autosave destroying an outside edit — a read tool
    /// silently enabling data loss. The operations layer parses the file
    /// directly instead, and this pins that.
    @Test func readingDoesNotDisarmTheExternalChangeGuard() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Guarded")
        note.body = "mine"
        try store.save(note)
        try externallyEditFile(note.path, to: "theirs")

        let read = await run(operations, ["operation": "read", "note": note.id])
        #expect(read.isError == false)
        #expect(store.externalChangeDetected(for: note),
                "read_note re-baselined the mtime — the external-change guard is now disarmed")
    }

    @Test func listTagsAndFoldersAnswerFromTheVault() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Tagged")
        note.tags = ["zeta", "alpha"]
        try store.save(note)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("inbox"), withIntermediateDirectories: true)

        let tags = await run(operations, ["operation": "listTags"])
        #expect(tags.text == "alpha\nzeta")
        let folders = await run(operations, ["operation": "listFolders"])
        #expect(folders.text == "inbox")
    }

    // MARK: - write

    @Test func createWritesTitleBodyAndTags() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await run(operations, [
            "operation": "create", "title": "Made", "body": "fresh", "tags": ["x"],
        ])
        #expect(outcome.isError == false)
        let row = try #require(store.rows.first { $0.title == "Made" })
        #expect(row.tags == ["x"])
        #expect(try String(contentsOf: row.path, encoding: .utf8).contains("fresh"))
    }

    @Test func createRequiresATitle() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "create", "title": "  "])
        #expect(outcome.isError)
        #expect(outcome.text.contains("title"))
    }

    /// The reason `save_note` can be classified non-destructive: an omitted
    /// field is left alone, so a call that only adds a tag cannot blank a body
    /// the model never read.
    @Test func savePatchesRatherThanReplacing() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Patched")
        note.body = "keep me"
        try store.save(note)

        let outcome = await run(operations, [
            "operation": "save", "note": note.id, "tags": ["added"],
        ])
        #expect(outcome.isError == false)
        let text = try String(contentsOf: note.path, encoding: .utf8)
        #expect(text.contains("keep me"), "an omitted body was blanked")
        #expect(text.contains("added"))
    }

    @Test func saveRefusesAnExternalChangeAndNamesTheOtherTool() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Contested")
        note.body = "mine"
        try store.save(note)
        try externallyEditFile(note.path, to: "theirs")

        let outcome = await run(operations, [
            "operation": "save", "note": note.id, "body": "mine again",
        ])
        #expect(outcome.isError)
        #expect(outcome.text.contains("save_note_overwriting"))
        #expect(try String(contentsOf: note.path, encoding: .utf8).contains("theirs"),
                "the outside edit was destroyed by a refused save")
    }

    @Test func saveWithTheInjectedFlagOverwritesTheExternalChange() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Overwritten")
        note.body = "mine"
        try store.save(note)
        try externallyEditFile(note.path, to: "theirs")

        let outcome = await run(operations, [
            "operation": "save", "note": note.id, "body": "mine again",
            "overwritingExternalChanges": true,
        ])
        #expect(outcome.isError == false)
        #expect(try String(contentsOf: note.path, encoding: .utf8).contains("mine again"))
    }

    @Test func deleteRemovesTheFileAndTheRow() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try store.create(title: "Doomed")

        let outcome = await run(operations, ["operation": "delete", "note": note.id])
        #expect(outcome.isError == false)
        #expect(FileManager.default.fileExists(atPath: note.path.path) == false)
        #expect(store.rows.isEmpty)
    }

    // MARK: - identifier handling

    @Test func anAbsolutePathIdentifiesANoteToo() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try store.create(title: "ByPath")

        let outcome = await run(operations, ["operation": "read", "note": note.path.path])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains("title: ByPath"))
    }

    @Test func anUnknownIdentifierIsAnActionableError() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "read", "note": "no-such-id"])
        #expect(outcome.isError)
        #expect(outcome.text.contains("search_notes"))
    }

    @Test func aMissingIdentifierIsAnActionableError() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "delete"])
        #expect(outcome.isError)
        #expect(outcome.text.contains("\"note\""))
    }

    /// `tags: "a, b"` is ambiguous — one tag or two? Guessing would silently
    /// mangle metadata, so a non-array is ignored rather than coerced.
    @Test func aBareStringIsNotCoercedIntoATagList() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Tagless")
        note.tags = ["original"]
        try store.save(note)

        _ = await run(operations, ["operation": "save", "note": note.id, "tags": "a, b"])
        let row = try #require(store.rows.first { $0.id == note.id })
        #expect(row.tags == ["original"])
    }

    @Test func anUnknownOperationIsAnError() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "launchMissiles"])
        #expect(outcome.isError)
        #expect(outcome.text.contains("unknown operation"))
    }
}

/// Rewrites a note's file behind the store's back and forces its mtime forward.
/// The explicit bump keeps the assertion on the guard rather than on filesystem
/// timestamp granularity.
private func externallyEditFile(_ url: URL, to body: String) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    let head = text.components(separatedBy: "---").prefix(3).joined(separator: "---")
    try (head + "\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
}
