import XCTest
@testable import LoreFeature

final class EngineRegistryTests: XCTestCase {
    private func tempFile(_ name: String, _ contents: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-engine-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_registry_hasAtLeastOneEngine() throws {
        XCTAssertFalse(EngineRegistry.engines.isEmpty)
    }

    func test_registry_returnsNilForUnclaimedType() throws {
        let url = try tempFile("sheet.xlsx", "binary-ish")
        XCTAssertNil(EngineRegistry.engine(for: url))
    }

    func test_load_dispatchesThroughTheRegisteredEngine() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: Hello
        ---
        searchable haystack
        """)
        let engine = try EngineRegistry.load(url)
        XCTAssertEqual(engine.indexPayload.title, "Hello")
        XCTAssertTrue(engine.indexPayload.plaintext.contains("haystack"))
    }

    func test_load_throwsUnsupportedForAnUnclaimedType() throws {
        let url = try tempFile("sheet.xlsx", "binary-ish")
        XCTAssertThrowsError(try EngineRegistry.load(url)) { error in
            XCTAssertEqual(error as? EngineError, .unsupported(url))
        }
    }

    func test_engineIdentifiersAreUnique() {
        let ids = EngineRegistry.engines.map { $0.identifier }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate engine identifiers: \(ids)")
    }
}

final class MarkdownEngineTests: XCTestCase {
    private func tempFile(_ name: String, _ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-md-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_canOpen_claimsMarkdownOnly() throws {
        XCTAssertTrue(MarkdownEngine.canOpen(URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertFalse(MarkdownEngine.canOpen(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(MarkdownEngine.canOpen(URL(fileURLWithPath: "/tmp/a.pdf")))
    }

    func test_indexPayload_exposesTitleTagsAndBody() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: Hello
        tags: [x, y]
        ---
        searchable haystack
        """)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.indexPayload.title, "Hello")
        XCTAssertEqual(engine.indexPayload.tags, ["x", "y"])
        XCTAssertTrue(engine.indexPayload.plaintext.contains("haystack"))
    }

    func test_outline_listsHeadings() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: T
        ---
        # One
        text
        ## Two
        """)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.indexPayload.outline,
                       [OutlineEntry(level: 1, text: "One"), OutlineEntry(level: 2, text: "Two")])
    }

    func test_saveThenLoad_preservesUnmodelledProperties() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: T
        status: active
        ---
        body
        """)
        let engine = try MarkdownEngine.load(url)
        try engine.save(to: url)
        let reloaded = try MarkdownEngine.load(url)
        XCTAssertEqual(reloaded.note.extra.map(\.key), ["status"])
    }
}

/// Run against EVERY registered engine. M3-M5 engines inherit these by
/// registering — that is the point of the suite.
final class EngineConformanceTests: XCTestCase {

    /// A minimal valid document each engine can load, keyed by identifier.
    /// A new engine must add its sample here, which is the forcing function
    /// that keeps this suite honest.
    /// Each sample must be byte-identical to what its engine's own `save`
    /// re-emits after a no-op load, since `test_loadSaveLoad_isByteStable`
    /// asserts against the ORIGINAL contents, not just idempotency. The
    /// markdown sample is deliberately a REAL Obsidian shape — block-sequence
    /// `tags` and `aliases` plus a comment — because those are exactly what a
    /// model-re-emitting serializer destroys. The assertion stays strict.
    private static let samples: [String: (name: String, contents: String)] = [
        "markdown": ("c.md", "---\nid: a\ntitle: T\ntags:\n  - alpha\n  - beta\ncreated: 2026-01-01\nupdated: 2026-01-01\naliases:\n  - one\n# a trailing comment\n---\nbody"),
        "plaintext": ("c.txt", "plain body text"),
    ]

    private func write(_ name: String, _ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-conf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_everyEngineHasASample() {
        for engine in EngineRegistry.engines {
            XCTAssertNotNil(Self.samples[engine.identifier],
                            "engine \(engine.identifier) has no conformance sample")
        }
    }

    func test_loadSaveLoad_isByteStable() throws {
        for engine in EngineRegistry.engines {
            guard let sample = Self.samples[engine.identifier] else { continue }
            let url = try write(sample.name, sample.contents)
            let loaded = try engine.load(url)
            try loaded.save(to: url)
            let after = try String(contentsOf: url, encoding: .utf8)
            // The load-then-save-with-no-mutation round trip must reproduce
            // the ORIGINAL bytes. Comparing only two successive saves (as an
            // earlier version of this test did) would pass even for an engine
            // that strips data on every save — it only proves idempotency,
            // not fidelity.
            XCTAssertEqual(after, sample.contents,
                           "\(engine.identifier): save does not round-trip the original bytes")
            try loaded.save(to: url)
            let afterTwice = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(after, afterTwice,
                           "\(engine.identifier): save is not idempotent")
        }
    }

    func test_canOpenIsMutuallyExclusive() throws {
        for engine in EngineRegistry.engines {
            guard let sample = Self.samples[engine.identifier] else { continue }
            let url = try write(sample.name, sample.contents)
            let claimers = EngineRegistry.engines.filter { $0.canOpen(url) }
            XCTAssertEqual(claimers.count, 1,
                           "\(sample.name) claimed by \(claimers.map { $0.identifier })")
        }
    }

    func test_indexPayload_survivesAdversarialInput() throws {
        let cases: [(String, String)] = [
            ("empty", ""),
            ("huge", String(repeating: "lorem ipsum ", count: 200_000)),
            ("binaryish", String(decoding: Data((0...255).map(UInt8.init)), as: UTF8.self)),
        ]
        for engine in EngineRegistry.engines {
            guard let sample = Self.samples[engine.identifier] else { continue }
            let ext = (sample.name as NSString).pathExtension
            for (label, contents) in cases {
                let url = try write("adversarial-\(label).\(ext)", contents)
                let loaded = try engine.load(url)
                let payload = loaded.indexPayload
                XCTAssertNotNil(payload.plaintext,
                                "\(engine.identifier)/\(label) produced no plaintext")
            }
        }
    }

    func test_registryHasAtLeastTwoEngines() {
        XCTAssertGreaterThanOrEqual(EngineRegistry.engines.count, 2)
    }

    func test_markdownIndexPayloadCarriesLinksAndAliases() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-links-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("n.md")
        try """
        ---
        id: a
        title: T
        aliases: [Alt]
        ---
        see [[Other]] and ![[Pic]]
        """.write(to: url, atomically: true, encoding: .utf8)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.indexPayload.links.map(\.rawTarget), ["Other", "Pic"])
        XCTAssertEqual(engine.indexPayload.links.last?.isEmbed, true)
        XCTAssertEqual(engine.indexPayload.aliases, ["Alt"])
    }
}

/// PlainTextEngine's lossy-decode / refuse-to-save contract. A lossily-decoded
/// document is legitimately unsaveable, so it is deliberately kept out of
/// `EngineConformanceTests.samples` rather than added as a case there.
final class PlainTextEngineTests: XCTestCase {
    private func write(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-plaintext-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func test_load_ofInvalidUTF8_succeedsAndFlagsLossyDecode() throws {
        // 0xFF is not a valid UTF-8 lead byte in any position.
        let data = Data([0x48, 0x69, 0xFF, 0x21])
        let url = try write("bad.txt", data)
        let engine = try PlainTextEngine.load(url)
        XCTAssertTrue(engine.isLossilyDecoded)
        XCTAssertFalse(engine.indexPayload.plaintext.isEmpty)
    }

    func test_save_ofLossilyDecodedDocument_throwsNotRoundTrippable() throws {
        let data = Data([0x48, 0x69, 0xFF, 0x21])
        let url = try write("bad.txt", data)
        let engine = try PlainTextEngine.load(url)
        XCTAssertThrowsError(try engine.save(to: url)) { error in
            XCTAssertEqual(error as? EngineError, .notRoundTrippable(url))
        }
    }

    func test_load_ofValidUTF8_isNotLossyAndSavesFine() throws {
        let data = Data("hello world".utf8)
        let url = try write("good.txt", data)
        let engine = try PlainTextEngine.load(url)
        XCTAssertFalse(engine.isLossilyDecoded)
        XCTAssertNoThrow(try engine.save(to: url))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "hello world")
    }
}
