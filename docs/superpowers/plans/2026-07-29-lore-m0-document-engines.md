# Lore M0 — Document-Engine Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Lore's hardcoded "a document is a markdown file" assumption with a document-engine registry, so every later milestone (PDF, rich text, database views) is "add an engine" rather than "modify the shell."

**Architecture:** A `DocumentEngine` protocol owns type detection, load/save, an `IndexPayload` for the search index, and an editor view. `LoreStore` splits into `VaultIndexCoordinator` (vault + watcher + index), `DocumentSession` (one per open tab: dirty state, autosave, conflict), and a thin `LoreStore` facade. The SQLite `notes` table generalizes to `documents` with `type`, `properties`, and engine-supplied `plaintext`.

**Tech Stack:** Swift 6.0, SwiftUI, macOS 14.0+, GRDB 6.29.3 (SQLite + FTS5), AinkradAppKit (host plugin SDK), XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-29-lore-document-engines-design.md`

## Global Constraints

- Swift 6.0, strict concurrency. `MACOSX_DEPLOYMENT_TARGET` 14.0.
- **No source file may exceed 500 lines.** Split before crossing.
- Build/test only via `make` — `make test` (runs XcodeGen then `xcodebuild test`), `make build`, `make sideload`. Never invoke `swift build`/`swift test`; this is an Xcode bundle target, not a SwiftPM package.
- `DEVELOPER_DIR` defaults to `/Applications/Xcode-beta.app/Contents/Developer` (set in the Makefile).
- New source files must be added under `Sources/LoreFeature/...`; XcodeGen picks up directories automatically via `sources: [Sources/LoreFeature]`. Run `make generate` after adding directories.
- All existing tests in `Tests/LoreFeatureTests/` must stay green at every task boundary. A red pre-existing test means the refactor changed behavior.
- The index is **derived state**. The file on disk is truth. Never fail a save because an index write failed.
- **Do NOT run `git commit`, `git push`, or merge.** This repository operates under a review gate: implement, `git add` the relevant paths, then stop and report. The human approves commits after reading the report.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `Sources/LoreFeature/Documents/LoreDocument.swift` | `LoreDocument` value type, `IndexPayload`, `EditorContext` |
| `Sources/LoreFeature/Documents/DocumentEngine.swift` | `DocumentEngine` protocol |
| `Sources/LoreFeature/Documents/EngineRegistry.swift` | Engine lookup + ordered resolution + fallback |
| `Sources/LoreFeature/Documents/Markdown/MarkdownEngine.swift` | Markdown engine (wraps `Frontmatter`/`Note`) |
| `Sources/LoreFeature/Documents/PlainText/PlainTextEngine.swift` | Plain-text/code engine |
| `Sources/LoreFeature/Documents/Fallback/FallbackViewer.swift` | Read-only viewer for unclaimed types + load-error state |
| `Sources/LoreFeature/Store/VaultIndexCoordinator.swift` | Vault root, watcher, coalesced rescan, index ownership |
| `Sources/LoreFeature/Store/DocumentSession.swift` | Per-tab document state: dirty, autosave, conflict |
| `Sources/LoreFeature/Views/TabBarView.swift` | Tab strip UI |
| `Sources/LoreFeature/Views/DocumentPane.swift` | Routes a session to its engine's editor / error / fallback view |
| `Tests/LoreFeatureTests/EngineConformanceTests.swift` | Generic suite run against every registered engine |
| `Tests/LoreFeatureTests/DocumentSessionTests.swift` | Dirty/autosave/conflict behavior |
| `Tests/LoreFeatureTests/TabsTests.swift` | Tab lifecycle |

**Modified:**

| Path | Change |
|---|---|
| `Sources/LoreFeature/Logic/Frontmatter.swift` | Ordered `extra` round-trip |
| `Sources/LoreFeature/Models/Note.swift` | Carries `extra` |
| `Sources/LoreFeature/Store/LoreIndex.swift` | `documents` table, `type`/`properties`/`plaintext`, `user_version` |
| `Sources/LoreFeature/Store/LoreStore.swift` | Reduced to facade + tab list |
| `Sources/LoreFeature/Views/LoreRootView.swift` | Tab bar + `DocumentPane` |
| `Sources/LoreFeature/Views/NoteEditorPane.swift` | Becomes the markdown engine's editor, driven by `DocumentSession` |
| `Sources/LoreFeature/MCP/LoreNoteOperations.swift` | Adapted to the facade's new API |

---

### Task 1: Lossless frontmatter round-trip

Prerequisite for everything else. Today `Frontmatter.serialize` emits a fixed five-key block, so any other property (`aliases`, `cssclasses`, the Ainkrad pipeline's `status`/`source`/`type`) is deleted on first save.

**Files:**
- Modify: `Sources/LoreFeature/Models/Note.swift`
- Modify: `Sources/LoreFeature/Logic/Frontmatter.swift`
- Test: `Tests/LoreFeatureTests/FrontmatterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Note.extra: [FrontmatterPair]`, `struct FrontmatterPair: Equatable, Sendable { let key: String; let rawValue: String }`. `Frontmatter.parse(_:path:) -> Note` and `Frontmatter.serialize(_:) -> String` keep their existing signatures.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LoreFeatureTests/FrontmatterTests.swift`:

```swift
func test_parse_capturesUnmodelledKeysInOrder() {
    let text = """
    ---
    id: abc
    aliases: [one, two]
    title: Kept
    status: active
    ---
    body text
    """
    let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/x.md"))
    XCTAssertEqual(note.extra.map(\.key), ["aliases", "status"])
    XCTAssertEqual(note.extra.first?.rawValue, "[one, two]")
}

func test_serialize_reemitsUnmodelledKeys() {
    let text = """
    ---
    id: abc
    title: Kept
    status: active
    cssclasses: wide
    ---
    body text
    """
    let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/x.md"))
    let out = Frontmatter.serialize(note)
    XCTAssertTrue(out.contains("status: active"), out)
    XCTAssertTrue(out.contains("cssclasses: wide"), out)
}

func test_roundTrip_isStableAcrossTwoPasses() {
    let text = """
    ---
    id: abc
    title: Kept
    tags: [a, b]
    created: 2026-01-01
    updated: 2026-01-02
    source: https://example.com
    ---
    body text
    """
    let path = URL(fileURLWithPath: "/tmp/x.md")
    let once = Frontmatter.serialize(Frontmatter.parse(text, path: path))
    let twice = Frontmatter.serialize(Frontmatter.parse(once, path: path))
    XCTAssertEqual(once, twice)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | grep -E "FrontmatterTests|error:"`
Expected: FAIL — `value of type 'Note' has no member 'extra'` (compile error is a valid failing state here).

- [ ] **Step 3: Add `extra` to the model**

In `Sources/LoreFeature/Models/Note.swift`, add the pair type and the property, defaulting in the initializer so existing call sites keep compiling:

```swift
public struct FrontmatterPair: Equatable, Sendable {
    public let key: String
    public let rawValue: String
    public init(key: String, rawValue: String) { self.key = key; self.rawValue = rawValue }
}
```

Add `public var extra: [FrontmatterPair]` to `Note`, and to its initializer as `extra: [FrontmatterPair] = []`, assigned in the body.

- [ ] **Step 4: Capture unmodelled keys in `parse`**

In `Frontmatter.parse`, alongside the existing `kv` dictionary build, accumulate an ordered list of the keys that are not modelled:

```swift
let modelled: Set<String> = ["id", "title", "tags", "created", "updated"]
var extra: [FrontmatterPair] = []
for line in header.split(separator: "\n", omittingEmptySubsequences: true) {
    guard let colon = line.firstIndex(of: ":") else { continue }
    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    kv[key] = value
    if !modelled.contains(key) { extra.append(FrontmatterPair(key: key, rawValue: value)) }
}
```

Replace the existing `for line in header...` loop with the above, and pass `extra: extra` into the returned `Note`. Also pass `extra: []` in `fallback`.

- [ ] **Step 5: Re-emit unmodelled keys in `serialize`**

```swift
public static func serialize(_ note: Note) -> String {
    let tags = "[" + note.tags.joined(separator: ", ") + "]"
    let extra = note.extra.map { "\($0.key): \($0.rawValue)" }.joined(separator: "\n")
    let extraBlock = extra.isEmpty ? "" : extra + "\n"
    return """
    ---
    id: \(note.id)
    title: \(note.title)
    tags: \(tags)
    created: \(iso.string(from: note.created))
    updated: \(iso.string(from: note.updated))
    \(extraBlock)---
    \(note.body)
    """
}
```

Unmodelled keys are re-emitted after the modelled block, in their original relative order. Values are re-emitted as raw source text — Lore preserves what it does not model and does not attempt to understand it.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test 2>&1 | tail -30`
Expected: PASS, including all pre-existing `FrontmatterTests` and `LoreStoreTests`.

- [ ] **Step 7: Stage (do not commit)**

```bash
git add Sources/LoreFeature/Models/Note.swift Sources/LoreFeature/Logic/Frontmatter.swift Tests/LoreFeatureTests/FrontmatterTests.swift
```

---

### Task 2: `DocumentEngine` protocol and registry

**Files:**
- Create: `Sources/LoreFeature/Documents/LoreDocument.swift`
- Create: `Sources/LoreFeature/Documents/DocumentEngine.swift`
- Create: `Sources/LoreFeature/Documents/EngineRegistry.swift`
- Test: `Tests/LoreFeatureTests/EngineConformanceTests.swift`

**Interfaces:**
- Consumes: `FrontmatterPair` (Task 1).
- Produces:
  - `struct IndexPayload: Sendable { var title: String; var plaintext: String; var tags: [String]; var properties: [FrontmatterPair]; var outline: [OutlineEntry]; var links: [String] }`
  - `struct OutlineEntry: Sendable, Equatable { let level: Int; let text: String }`
  - `protocol DocumentEngine: AnyObject` with `static var identifier: String`, `static func canOpen(_ url: URL) -> Bool`, `static func load(_ url: URL) throws -> Self`, `func save(to url: URL) throws`, `var indexPayload: IndexPayload { get }`, `@MainActor func makeEditor(_ ctx: EditorContext) -> AnyView`.
  - `enum EngineRegistry` with `static var engines: [any DocumentEngine.Type]`, `static func engine(for url: URL) -> (any DocumentEngine.Type)?`, `static func load(_ url: URL) throws -> any DocumentEngine`.
  - `struct EditorContext` with `let theme: HostTheme`, `let onChange: @MainActor () -> Void`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LoreFeatureTests/EngineConformanceTests.swift`:

```swift
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

    func test_registry_hasAtLeastOneEngine() {
        XCTAssertFalse(EngineRegistry.engines.isEmpty)
    }

    func test_registry_returnsNilForUnclaimedType() throws {
        let url = try tempFile("sheet.xlsx", "binary-ish")
        XCTAssertNil(EngineRegistry.engine(for: url))
    }

    func test_engineIdentifiersAreUnique() {
        let ids = EngineRegistry.engines.map { $0.identifier }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate engine identifiers: \(ids)")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "EngineRegistry|error:"`
Expected: FAIL — `cannot find 'EngineRegistry' in scope`.

- [ ] **Step 3: Create `LoreDocument.swift`**

```swift
import SwiftUI
import AinkradAppKit

/// A heading in a document, for outline navigation (M2 consumes this; M0 only
/// has to carry it so engines do not need a schema change later).
public struct OutlineEntry: Sendable, Equatable {
    public let level: Int
    public let text: String
    public init(level: Int, text: String) { self.level = level; self.text = text }
}

/// Everything the shell needs to index a document, supplied BY the engine.
///
/// The shell never re-reads a document's file to index it. That indirection is
/// what lets a PDF or a `.lore` package contribute searchable text it does not
/// literally contain as bytes.
public struct IndexPayload: Sendable {
    public var title: String
    public var plaintext: String
    public var tags: [String]
    public var properties: [FrontmatterPair]
    public var outline: [OutlineEntry]
    /// Outbound link targets. Always empty in M0; M1 populates it.
    public var links: [String]

    public init(title: String, plaintext: String, tags: [String] = [],
                properties: [FrontmatterPair] = [], outline: [OutlineEntry] = [],
                links: [String] = []) {
        self.title = title; self.plaintext = plaintext; self.tags = tags
        self.properties = properties; self.outline = outline; self.links = links
    }
}

/// What an engine's editor view needs from the shell.
public struct EditorContext {
    public let theme: HostTheme
    /// Called by the editor after every user mutation. The session debounces
    /// and saves; the editor never writes files itself.
    public let onChange: @MainActor () -> Void

    public init(theme: HostTheme, onChange: @escaping @MainActor () -> Void) {
        self.theme = theme; self.onChange = onChange
    }
}
```

- [ ] **Step 4: Create `DocumentEngine.swift`**

```swift
import SwiftUI

/// One document type: how to detect it, load it, save it, index it, and edit it.
///
/// Class-bound so a loaded document is a reference the session mutates in place
/// and the editor view binds to.
public protocol DocumentEngine: AnyObject {
    /// Stable identifier, stored in the index's `type` column.
    static var identifier: String { get }

    /// True when this engine claims `url`. Must be mutually exclusive with
    /// every other registered engine — `EngineConformanceTests` enforces it.
    static func canOpen(_ url: URL) -> Bool

    static func load(_ url: URL) throws -> Self

    func save(to url: URL) throws

    var indexPayload: IndexPayload { get }

    @MainActor func makeEditor(_ ctx: EditorContext) -> AnyView
}
```

- [ ] **Step 5: Create `EngineRegistry.swift`**

```swift
import Foundation

/// Ordered engine lookup. Order is significance order: the first engine whose
/// `canOpen` returns true wins. Engines are required to be mutually exclusive,
/// so order is a tie-break that should never actually be needed — it exists so
/// a bug produces deterministic behavior rather than a coin flip.
public enum EngineRegistry {
    public static let engines: [any DocumentEngine.Type] = [
        MarkdownEngine.self,
        PlainTextEngine.self,
    ]

    public static func engine(for url: URL) -> (any DocumentEngine.Type)? {
        engines.first { $0.canOpen(url) }
    }

    /// Loads `url` with whichever engine claims it.
    /// Throws `EngineError.unsupported` when none does — the caller renders the
    /// read-only fallback viewer rather than pretending the file is not there.
    public static func load(_ url: URL) throws -> any DocumentEngine {
        guard let engine = engine(for: url) else { throw EngineError.unsupported(url) }
        return try engine.load(url)
    }
}

public enum EngineError: Error, Equatable {
    case unsupported(URL)
}
```

Note: this will not compile until Tasks 3 and 4 add `MarkdownEngine` and `PlainTextEngine`. That is intentional — the registry is the contract those tasks fill.

- [ ] **Step 6: Temporarily empty the registry so this task builds green**

Set `engines` to `[]` with this comment, so Task 2 is independently verifiable:

```swift
    // Populated by Task 3 (MarkdownEngine) and Task 4 (PlainTextEngine).
    public static let engines: [any DocumentEngine.Type] = []
```

Then change `test_registry_hasAtLeastOneEngine` to be `XCTSkip`-guarded for now:

```swift
    func test_registry_hasAtLeastOneEngine() throws {
        try XCTSkipIf(EngineRegistry.engines.isEmpty, "engines land in Tasks 3-4")
        XCTAssertFalse(EngineRegistry.engines.isEmpty)
    }
```

Task 4 removes the skip.

- [ ] **Step 7: Regenerate the project and run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS. (`make generate` is required — a new `Documents/` directory tree was added.)

- [ ] **Step 8: Stage**

```bash
git add Sources/LoreFeature/Documents Tests/LoreFeatureTests/EngineConformanceTests.swift AinkradLore.xcodeproj
```

---

### Task 3: Markdown engine

Behavior-preserving extraction: the markdown engine wraps the existing `Note` + `Frontmatter` code rather than reimplementing it.

**Files:**
- Create: `Sources/LoreFeature/Documents/Markdown/MarkdownEngine.swift`
- Modify: `Sources/LoreFeature/Documents/EngineRegistry.swift`
- Test: `Tests/LoreFeatureTests/EngineConformanceTests.swift`

**Interfaces:**
- Consumes: `DocumentEngine`, `IndexPayload`, `EditorContext` (Task 2); `Note`, `Frontmatter`, `FrontmatterPair` (Task 1).
- Produces: `final class MarkdownEngine: DocumentEngine` with `var note: Note` and `static let identifier = "markdown"`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LoreFeatureTests/EngineConformanceTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "MarkdownEngine|error:"`
Expected: FAIL — `cannot find 'MarkdownEngine' in scope`.

- [ ] **Step 3: Create `MarkdownEngine.swift`**

```swift
import SwiftUI
import AinkradAppKit

/// Markdown documents: plain `.md` with YAML frontmatter, read and written
/// verbatim and safe to open in Obsidian.
///
/// A thin adapter over the existing `Note` + `Frontmatter` pair. Loading and
/// saving must stay byte-identical to what `LoreStore` did before M0 — this is
/// an extraction, not a rewrite.
public final class MarkdownEngine: DocumentEngine {
    public static let identifier = "markdown"

    public var note: Note

    private init(note: Note) { self.note = note }

    public static func canOpen(_ url: URL) -> Bool {
        ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
    }

    public static func load(_ url: URL) throws -> MarkdownEngine {
        let text = try String(contentsOf: url, encoding: .utf8)
        return MarkdownEngine(note: Frontmatter.parse(text, path: url))
    }

    public func save(to url: URL) throws {
        try Frontmatter.serialize(note).write(to: url, atomically: true, encoding: .utf8)
    }

    public var indexPayload: IndexPayload {
        IndexPayload(title: note.title,
                     plaintext: note.body,
                     tags: note.tags,
                     properties: note.extra,
                     outline: Self.outline(of: note.body))
    }

    /// ATX headings only (`# ` … `###### `). Setext headings are rare in
    /// generated vaults and M2 owns full markdown parsing; keeping this
    /// deliberately dumb avoids two competing parsers.
    static func outline(of body: String) -> [OutlineEntry] {
        body.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let hashes = line.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count),
                  line.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
            let text = line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : OutlineEntry(level: hashes.count, text: text)
        }
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        AnyView(MarkdownDocumentEditor(engine: self, ctx: ctx))
    }
}
```

- [ ] **Step 4: Create the editor view in the same file**

Appended below `MarkdownEngine` (keeps the file well under 500 lines and keeps the engine and its view together — they change together):

```swift
/// The markdown engine's editor. Owns no persistence: it mutates the engine's
/// note and calls `ctx.onChange`, and `DocumentSession` decides when to write.
@MainActor
private struct MarkdownDocumentEditor: View {
    let engine: MarkdownEngine
    let ctx: EditorContext
    @State private var title: String = ""
    @State private var body_: String = ""

    var body: some View {
        VStack(spacing: 0) {
            AinkradTextField(text: $title, placeholder: "Title")
                .padding(AinkradSpacing.md)
                .onChange(of: title) { engine.note.title = title; ctx.onChange() }

            MarkdownEditor(text: $body_, tokens: ctx.theme.tokens)
                .onChange(of: body_) { engine.note.body = body_; ctx.onChange() }
        }
        .background(ctx.theme.tokens.background)
        .onAppear { title = engine.note.title; body_ = engine.note.body }
    }
}
```

- [ ] **Step 5: Register the engine**

In `EngineRegistry.swift`, replace the empty array:

```swift
    public static let engines: [any DocumentEngine.Type] = [
        MarkdownEngine.self,
    ]
```

- [ ] **Step 6: Run tests**

Run: `make test 2>&1 | tail -30`
Expected: PASS — `MarkdownEngineTests` green, `test_registry_returnsNilForUnclaimedType` still green (`.xlsx` unclaimed), all pre-existing tests green.

- [ ] **Step 7: Stage**

```bash
git add Sources/LoreFeature/Documents Tests/LoreFeatureTests/EngineConformanceTests.swift
```

---

### Task 4: Plain-text engine and the generic conformance suite

The second engine exists to prove the abstraction is not secretly markdown-shaped, and to give the conformance suite two subjects.

**Files:**
- Create: `Sources/LoreFeature/Documents/PlainText/PlainTextEngine.swift`
- Modify: `Sources/LoreFeature/Documents/EngineRegistry.swift`
- Test: `Tests/LoreFeatureTests/EngineConformanceTests.swift`

**Interfaces:**
- Consumes: `DocumentEngine`, `IndexPayload`, `EditorContext` (Task 2).
- Produces: `final class PlainTextEngine: DocumentEngine` with `var text: String` and `static let identifier = "plaintext"`; `PlainTextEngine.extensions: Set<String>`.

- [ ] **Step 1: Write the failing conformance suite**

Append to `Tests/LoreFeatureTests/EngineConformanceTests.swift`:

```swift
/// Run against EVERY registered engine. M3-M5 engines inherit these by
/// registering — that is the point of the suite.
final class EngineConformanceTests: XCTestCase {

    /// A minimal valid document each engine can load, keyed by identifier.
    /// A new engine must add its sample here, which is the forcing function
    /// that keeps this suite honest.
    private static let samples: [String: (name: String, contents: String)] = [
        "markdown": ("c.md", "---\nid: a\ntitle: T\n---\nbody"),
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
}
```

Also delete the `XCTSkipIf` line added in Task 2 Step 6 from `test_registry_hasAtLeastOneEngine`.

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "Conformance|error:"`
Expected: FAIL — `cannot find 'PlainTextEngine' in scope`.

- [ ] **Step 3: Create `PlainTextEngine.swift`**

```swift
import SwiftUI
import AinkradAppKit

/// Plain text and source files: no frontmatter, no structure, the file's bytes
/// are the document.
///
/// Deliberately the dumbest possible engine. Its job in M0 is to prove the
/// shell contains no markdown assumptions — if anything here needs a special
/// case in `VaultIndexCoordinator` or `DocumentSession`, the abstraction leaks.
public final class PlainTextEngine: DocumentEngine {
    public static let identifier = "plaintext"

    public var text: String
    private let sourceURL: URL

    private init(text: String, sourceURL: URL) {
        self.text = text; self.sourceURL = sourceURL
    }

    public static let extensions: Set<String> = [
        "txt", "text", "log", "csv", "json", "yaml", "yml", "toml",
        "swift", "sh", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp",
    ]

    public static func canOpen(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func load(_ url: URL) throws -> PlainTextEngine {
        // Not every file with a text extension is valid UTF-8. Falling back to
        // a lossy decode keeps a mis-encoded log openable and searchable rather
        // than making it an error state the user cannot act on.
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        return PlainTextEngine(text: text, sourceURL: url)
    }

    public func save(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public var indexPayload: IndexPayload {
        IndexPayload(title: sourceURL.deletingPathExtension().lastPathComponent,
                     plaintext: text)
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        AnyView(PlainTextDocumentEditor(engine: self, ctx: ctx))
    }
}

@MainActor
private struct PlainTextDocumentEditor: View {
    let engine: PlainTextEngine
    let ctx: EditorContext
    @State private var text: String = ""

    var body: some View {
        MarkdownEditor(text: $text, tokens: ctx.theme.tokens)
            .onChange(of: text) { engine.text = text; ctx.onChange() }
            .onAppear { text = engine.text }
            .background(ctx.theme.tokens.background)
    }
}
```

`MarkdownEditor` is reused as a plain monospace text view — it is the project's existing themed text editor, and M2 is where syntax highlighting per type lands.

- [ ] **Step 4: Register it**

```swift
    public static let engines: [any DocumentEngine.Type] = [
        MarkdownEngine.self,
        PlainTextEngine.self,
    ]
```

- [ ] **Step 5: Run tests**

Run: `make test 2>&1 | tail -30`
Expected: PASS, all conformance tests green for both engines.

- [ ] **Step 6: Stage**

```bash
git add Sources/LoreFeature/Documents Tests/LoreFeatureTests/EngineConformanceTests.swift
```

---

### Task 5: Generalize the index to `documents`

**Files:**
- Modify: `Sources/LoreFeature/Store/LoreIndex.swift`
- Test: `Tests/LoreFeatureTests/LoreIndexTests.swift`

**Interfaces:**
- Consumes: `IndexPayload`, `FrontmatterPair`.
- Produces:
  - `IndexRow` gains `let type: String` and `let properties: [FrontmatterPair]`.
  - `LoreIndex.upsert(url:type:payload:updated:)`, `LoreIndex.replaceAll(with: [IndexEntry])`, `struct IndexEntry: Sendable { let url: URL; let type: String; let payload: IndexPayload; let updated: Date }`.
  - `LoreIndex.schemaVersion: Int32 = 2`.
- The old `upsert(_ note: Note)` / `replaceAll(with: [Note])` overloads are removed; Task 6 updates the callers.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LoreFeatureTests/LoreIndexTests.swift`:

```swift
func test_indexesEntriesOfAnyType() throws {
    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("idx-\(UUID()).sqlite")
    let index = try LoreIndex(path: dbURL)
    let entry = IndexEntry(
        url: URL(fileURLWithPath: "/tmp/a.txt"),
        type: "plaintext",
        payload: IndexPayload(title: "A", plaintext: "needle in here"),
        updated: Date())
    try index.replaceAll(with: [entry])
    XCTAssertEqual(try index.all().map(\.type), ["plaintext"])
    XCTAssertEqual(index.searchOrEmpty("needle").map(\.title), ["A"])
}

func test_storesProperties() throws {
    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("idx-\(UUID()).sqlite")
    let index = try LoreIndex(path: dbURL)
    let entry = IndexEntry(
        url: URL(fileURLWithPath: "/tmp/a.md"),
        type: "markdown",
        payload: IndexPayload(title: "A", plaintext: "b",
                              properties: [FrontmatterPair(key: "status", rawValue: "active")]),
        updated: Date())
    try index.replaceAll(with: [entry])
    XCTAssertEqual(try index.all().first?.properties.first?.key, "status")
}

func test_staleSchemaIsRebuiltNotRead() throws {
    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("idx-\(UUID()).sqlite")
    // Create a v1-shaped database by hand.
    let legacy = try DatabaseQueue(path: dbURL.path)
    try legacy.write { db in
        try db.execute(sql: "PRAGMA user_version = 1;")
        try db.execute(sql: "CREATE TABLE notes(path TEXT PRIMARY KEY);")
        try db.execute(sql: "INSERT INTO notes(path) VALUES('/tmp/old.md');")
    }
    _ = legacy   // release before reopening

    let index = try LoreIndex(path: dbURL)
    XCTAssertTrue(try index.all().isEmpty, "stale index should be discarded, not read")
}
```

Add `import GRDB` to the test file if not present, and add this helper to `LoreIndex` for test ergonomics:

```swift
    /// `search` throwing is never actionable at a call site; this is the shape
    /// every caller already used via `try?`.
    public func searchOrEmpty(_ query: String) -> [IndexRow] {
        (try? search(query)) ?? []
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "LoreIndexTests|error:"`
Expected: FAIL — `cannot find 'IndexEntry' in scope`.

- [ ] **Step 3: Add `IndexEntry` and widen `IndexRow`**

At the top of `LoreIndex.swift`:

```swift
public struct IndexEntry: Sendable {
    public let url: URL
    public let type: String
    public let payload: IndexPayload
    public let updated: Date
    public init(url: URL, type: String, payload: IndexPayload, updated: Date) {
        self.url = url; self.type = type; self.payload = payload; self.updated = updated
    }
}

public struct IndexRow: Equatable, Sendable {
    public let path: URL
    public let id: String
    public let title: String
    public let tags: [String]
    public let updated: Date
    public let type: String
    public let properties: [FrontmatterPair]
}
```

- [ ] **Step 4: Replace the schema and add versioned rebuild**

Replace `LoreIndex.init` with:

```swift
    /// Bump whenever the schema changes. On mismatch the file is deleted and
    /// rebuilt from disk — safe precisely because the index is derived state,
    /// so there is no migration SQL to get wrong.
    static let schemaVersion: Int32 = 2

    public init(path: URL) throws {
        var queue = try DatabaseQueue(path: path.path)
        let existing = try queue.read { db in
            try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        if existing != Self.schemaVersion {
            queue = try Self.recreate(at: path)
        }
        dbQueue = queue
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS documents(
                    path TEXT PRIMARY KEY, id TEXT, title TEXT, tags TEXT,
                    updated DOUBLE, plaintext TEXT, type TEXT, properties TEXT);
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts
                USING fts5(title, plaintext);
            """)
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    private static func recreate(at path: URL) throws -> DatabaseQueue {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                atPath: path.path + suffix)
        }
        return try DatabaseQueue(path: path.path)
    }
```

- [ ] **Step 5: Rewrite the write and read paths**

Replace `upsert`, `replaceAll`, `remove`, `all`, `search`, and `row` so they operate on `documents`/`documents_fts` and on `IndexEntry`. Keep the single-transaction batching in `replaceAll` and the standalone-FTS delete-then-insert pattern exactly as-is — both are load-bearing (see the existing comments, which must be preserved).

```swift
    private static func encode(_ properties: [FrontmatterPair]) -> String {
        properties.map { "\($0.key)\u{1F}\($0.rawValue)" }.joined(separator: "\u{1E}")
    }

    private static func decode(_ raw: String) -> [FrontmatterPair] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\u{1E}").compactMap { field in
            let parts = field.components(separatedBy: "\u{1F}")
            guard parts.count == 2 else { return nil }
            return FrontmatterPair(key: parts[0], rawValue: parts[1])
        }
    }
```

ASCII unit/record separators rather than JSON: property values are raw YAML source text that may contain quotes, braces, and newlines, and separators that cannot appear in a single-line YAML scalar are simpler and cheaper than escaping. M5 replaces this with typed columns when views need to query properties.

`upsert` becomes:

```swift
    public func upsert(_ entry: IndexEntry) throws {
        try dbQueue.write { db in
            try Self.write(entry, into: db)
        }
    }

    private static func write(_ entry: IndexEntry, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO documents(path,id,title,tags,updated,plaintext,type,properties)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                id=excluded.id, title=excluded.title, tags=excluded.tags,
                updated=excluded.updated, plaintext=excluded.plaintext,
                type=excluded.type, properties=excluded.properties;
        """, arguments: [entry.url.path, entry.url.path, entry.payload.title,
                         entry.payload.tags.joined(separator: ","),
                         entry.updated.timeIntervalSince1970,
                         entry.payload.plaintext, entry.type,
                         encode(entry.payload.properties)])
        let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path=?",
                                       arguments: [entry.url.path])
        try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
        try db.execute(sql: "INSERT INTO documents_fts(rowid,title,plaintext) VALUES(?,?,?)",
                       arguments: [rowid, entry.payload.title, entry.payload.plaintext])
    }
```

`replaceAll(with entries: [IndexEntry])` keeps its existing structure — one write transaction, `Self.write(entry, into: db)` per entry, then prune rows whose path is not in `keep`, deleting from `documents_fts` before `documents` in each case.

`row(_:)` becomes:

```swift
    private static func row(_ r: Row) -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: r["path"]),
                 id: r["id"], title: r["title"],
                 tags: (r["tags"] as String).split(separator: ",").map(String.init),
                 updated: Date(timeIntervalSince1970: r["updated"]),
                 type: r["type"],
                 properties: decode(r["properties"]))
    }
```

`all()` and `search(_:)` change only their table and FTS names (`notes` → `documents`, `notes_fts` → `documents_fts`). **`ftsExpression(for:)` is not touched** — it is a security/robustness fix with its own extensive rationale comment, and it must survive this task verbatim.

- [ ] **Step 6: Run tests**

Run: `make test 2>&1 | tail -40`
Expected: `LoreIndexTests` PASS. `LoreStoreTests` will FAIL TO COMPILE — its callers pass `Note`. That is expected and Task 6 fixes it; do not patch `LoreStore` here beyond what is needed to compile, and if you must, use the minimal adapter in Task 6 Step 3.

Since a non-compiling test target blocks everything, do Task 5 and Task 6 back-to-back without a green checkpoint between them, and treat Task 6's test run as the gate for both.

- [ ] **Step 7: Stage**

```bash
git add Sources/LoreFeature/Store/LoreIndex.swift Tests/LoreFeatureTests/LoreIndexTests.swift
```

---

### Task 6: Extract `VaultIndexCoordinator`

The vault-scanning machinery moves out of `LoreStore` **intact**. It is the most carefully tuned code in the project (off-actor rebuild, coalescing, self-write echo suppression) — relocate it, do not rewrite it, and carry every explanatory comment across unchanged.

**Files:**
- Create: `Sources/LoreFeature/Store/VaultIndexCoordinator.swift`
- Modify: `Sources/LoreFeature/Store/LoreStore.swift`
- Test: `Tests/LoreFeatureTests/LoreStoreTests.swift`

**Interfaces:**
- Consumes: `LoreIndex`, `IndexEntry` (Task 5); `EngineRegistry` (Tasks 2-4); `FolderWatcher`.
- Produces: `@MainActor @Observable final class VaultIndexCoordinator` with:
  - `init(indexPath: URL)`
  - `private(set) var rows: [IndexRow]`, `private(set) var vaultRoot: URL?`
  - `func activate(root: URL) throws`, `func shutdown()`, `func rebuild() throws`
  - `func search(_ query: String) -> [IndexRow]`
  - `func indexDocument(_ engine: any DocumentEngine, at url: URL) throws`
  - `func removeFromIndex(_ url: URL) throws`
  - `func suppressWatcher(for interval: TimeInterval)`
  - `func settleForTesting() async`
  - `nonisolated static func scanVault(at root: URL) -> [IndexEntry]`

- [ ] **Step 1: Write the failing test**

Append to `Tests/LoreFeatureTests/LoreStoreTests.swift`:

```swift
func test_scanVault_indexesEveryEngineOpenableType() throws {
    let root = tempDir()
    try "---\nid: a\ntitle: Note\n---\nalpha".write(
        to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try "beta text".write(
        to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    try "gamma".write(
        to: root.appendingPathComponent("c.xlsx"), atomically: true, encoding: .utf8)

    let entries = VaultIndexCoordinator.scanVault(at: root)
    XCTAssertEqual(Set(entries.map(\.type)), ["markdown", "plaintext"],
                   "unclaimed types must not be indexed")
}

func test_search_findsPlainTextDocuments() async throws {
    let root = tempDir()
    try "beta needle".write(
        to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    let s = try makeStore(root)
    await s.settleForTesting()
    try s.rebuild()
    XCTAssertEqual(s.search("needle").map(\.title), ["b"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "VaultIndexCoordinator|error:"`
Expected: FAIL — `cannot find 'VaultIndexCoordinator' in scope`.

- [ ] **Step 3: Create `VaultIndexCoordinator.swift`**

Move these members out of `LoreStore` verbatim, changing only what the types force:

- `vaultRoot`, `rows`, `index`, `watcher`, `suppressWatcherUntil`, `isRebuilding`, `rebuildRequestedAgain`, `selfWriteSuppressionWindow`
- `activate(root:)`, `shutdown()`, `handleVaultChange()`, `startBackgroundRebuild()`, `performBackgroundRebuild()`, `rebuild()`, `search(_:)`, `settleForTesting()`

`scanVault` is the one place that genuinely changes — it becomes engine-driven:

```swift
    /// Pure, off-actor: every engine-openable file under `root`, loaded and
    /// reduced to its index payload. No index access.
    ///
    /// Files no engine claims are skipped: they stay visible in Finder and can
    /// still be opened in the fallback viewer, but there is nothing meaningful
    /// to put in a full-text index for them.
    nonisolated static func scanVault(at root: URL) -> [IndexEntry] {
        var entries: [IndexEntry] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            // Skip package internals and tool directories: `.obsidian`,
            // `.git`, `.trash`, and (later) `.lore` package contents are not
            // documents in their own right.
            if url.pathComponents.contains(where: { $0.hasPrefix(".") }) { continue }
            guard let engineType = EngineRegistry.engine(for: url),
                  let engine = try? engineType.load(url) else { continue }
            let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            entries.append(IndexEntry(url: url, type: engineType.identifier,
                                      payload: engine.indexPayload, updated: updated))
        }
        return entries
    }
```

And add the two single-document index paths the session needs:

```swift
    /// Index one document after a save, without a whole-vault rescan.
    func indexDocument(_ engine: any DocumentEngine, at url: URL) throws {
        guard let index else { throw LoreError.noVault }
        let type = type(of: engine).identifier
        try index.upsert(IndexEntry(url: url, type: type,
                                    payload: engine.indexPayload, updated: Date()))
        rows = try index.all()
    }

    func removeFromIndex(_ url: URL) throws {
        guard let index else { throw LoreError.noVault }
        try index.remove(path: url)
        rows = try index.all()
    }

    /// Ignore watcher callbacks for `interval` — used across our own writes so
    /// a save does not trigger a full-vault rescan of a vault we just updated
    /// in place. See the original rationale on `save`.
    func suppressWatcher(for interval: TimeInterval) {
        suppressWatcherUntil = Date().addingTimeInterval(interval)
    }
```

- [ ] **Step 4: Reduce `LoreStore` to a facade over the coordinator**

`LoreStore` keeps `documents`/`defaultNoteFolder`/`subfolders`/`setVaultRoot`/`setDefaultNoteFolder`/`create`/`delete` and the `VaultBookmark` wiring, and forwards the rest:

```swift
    private let coordinator: VaultIndexCoordinator

    public var rows: [IndexRow] { coordinator.rows }
    public var vaultRoot: URL? { coordinator.vaultRoot }
    public func search(_ query: String) -> [IndexRow] { coordinator.search(query) }
    public func rebuild() throws { try coordinator.rebuild() }
    public func shutdown() { coordinator.shutdown() }
    func settleForTesting() async { await coordinator.settleForTesting() }
```

`create(title:)` keeps its slug/unique-URL logic but now writes through the markdown engine and indexes through the coordinator. `load(_:)` and `save(_:overwritingExternalChanges:)` move to `DocumentSession` in Task 7 — leave them in place for now so the MCP layer keeps compiling, delegating to the coordinator.

- [ ] **Step 5: Run tests**

Run: `make test 2>&1 | tail -40`
Expected: PASS — including every pre-existing `LoreStoreTests` case, which is the whole point of a behavior-preserving extraction.

- [ ] **Step 6: Verify no file exceeds 500 lines**

Run: `wc -l Sources/LoreFeature/**/*.swift | sort -rn | head -5`
Expected: every count below 500.

- [ ] **Step 7: Stage**

```bash
git add Sources/LoreFeature/Store Tests/LoreFeatureTests/LoreStoreTests.swift
```

---

### Task 7: `DocumentSession` — per-tab state, autosave, conflict resolution

**Files:**
- Create: `Sources/LoreFeature/Store/DocumentSession.swift`
- Test: `Tests/LoreFeatureTests/DocumentSessionTests.swift`

**Interfaces:**
- Consumes: `DocumentEngine`, `EngineRegistry`, `VaultIndexCoordinator`.
- Produces: `@MainActor @Observable final class DocumentSession` with:
  - `init(url: URL, engine: any DocumentEngine, coordinator: VaultIndexCoordinator)`
  - `static func open(url: URL, coordinator: VaultIndexCoordinator) throws -> DocumentSession`
  - `let url: URL`, `let engine: any DocumentEngine`
  - `private(set) var isDirty: Bool`, `private(set) var conflict: Bool`, `private(set) var loadError: Error?`
  - `func markChanged()`, `func saveNow() throws`, `func resolveByReloading() throws`, `func resolveByOverwriting() throws`, `func resolveBySavingCopy() throws -> URL`
  - `var title: String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/DocumentSessionTests.swift`:

```swift
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
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "DocumentSession|error:"`
Expected: FAIL — `cannot find 'DocumentSession' in scope`.

- [ ] **Step 3: Create `DocumentSession.swift`**

```swift
import Foundation
import Observation

/// One open document: its engine, its dirty state, its autosave, and its
/// conflict resolution.
///
/// The external-change guard used to live in `LoreStore.save` and applied only
/// to notes. It lives here now and applies to every document type, and the
/// three resolutions (reload / overwrite / save a copy) are real operations
/// rather than an error the UI had no affordance for.
@MainActor
@Observable
public final class DocumentSession {
    public let url: URL
    public let engine: any DocumentEngine

    public private(set) var isDirty = false
    public private(set) var conflict = false

    private let coordinator: VaultIndexCoordinator
    /// mtime as of the last successful load or save. Detection is mtime-based
    /// and therefore best-effort: a write inside the filesystem's timestamp
    /// granularity can still slip through. A much smaller hole than not
    /// checking at all.
    private var baseline: Date
    private var saveTask: Task<Void, Never>?

    private static let autosaveDelay: Duration = .milliseconds(500)
    private static let selfWriteSuppressionWindow: TimeInterval = 1.0

    public init(url: URL, engine: any DocumentEngine, coordinator: VaultIndexCoordinator) {
        self.url = url
        self.engine = engine
        self.coordinator = coordinator
        self.baseline = Self.mtime(of: url) ?? .distantPast
    }

    public static func open(url: URL, coordinator: VaultIndexCoordinator) throws -> DocumentSession {
        let engine = try EngineRegistry.load(url)
        return DocumentSession(url: url, engine: engine, coordinator: coordinator)
    }

    public var title: String { engine.indexPayload.title }

    /// Called by the engine's editor after every user mutation. Debounced, so
    /// typing produces one write per pause rather than one per keystroke.
    public func markChanged() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            // A conflict is surfaced, never swallowed: the editor's text stays
            // intact until the user chooses a resolution.
            try? self.saveNow()
        }
    }

    public func saveNow() throws {
        if let disk = Self.mtime(of: url), disk > baseline {
            conflict = true
            throw LoreError.externalChange(url)
        }
        try write()
    }

    public func resolveByOverwriting() throws {
        try write()
    }

    public func resolveByReloading() throws {
        let fresh = try EngineRegistry.load(url)
        // The engine is `let`, so reloading replaces the session rather than
        // mutating in place — callers swap the tab's session for this one.
        try copyState(from: fresh)
        baseline = Self.mtime(of: url) ?? .distantPast
        conflict = false
        isDirty = false
    }

    /// Writes our version beside the original as `name (Lore copy).ext`,
    /// leaving the on-disk file untouched. The escape hatch that makes the
    /// other two resolutions safe to offer.
    @discardableResult
    public func resolveBySavingCopy() throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(base) (Lore copy).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base) (Lore copy \(n)).\(ext)")
            n += 1
        }
        try engine.save(to: candidate)
        conflict = false
        isDirty = false
        return candidate
    }

    private func write() throws {
        coordinator.suppressWatcher(for: Self.selfWriteSuppressionWindow)
        try engine.save(to: url)
        baseline = Self.mtime(of: url) ?? .distantPast
        isDirty = false
        conflict = false
        // The file is truth; the index is derived. A failed index write must
        // never make a successful save look like a failure.
        try? coordinator.indexDocument(engine, at: url)
    }

    /// Replaces this session's engine contents with `fresh`'s. Implemented per
    /// engine because only the engine knows its own document model.
    private func copyState(from fresh: any DocumentEngine) throws {
        switch (engine, fresh) {
        case let (mine as MarkdownEngine, theirs as MarkdownEngine):
            mine.note = theirs.note
        case let (mine as PlainTextEngine, theirs as PlainTextEngine):
            mine.text = theirs.text
        default:
            throw EngineError.unsupported(url)
        }
    }

    private static func mtime(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
```

The `copyState` switch is the one place M0 leaks engine knowledge into the shell. Note it as the thing M3/M4 must fix by adding a `replaceContents(with:)` requirement to `DocumentEngine` — do not add it now, because with two engines the protocol requirement is speculative and the switch is honest about being temporary.

- [ ] **Step 4: Run tests**

Run: `make test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Stage**

```bash
git add Sources/LoreFeature/Store/DocumentSession.swift Tests/LoreFeatureTests/DocumentSessionTests.swift
```

---

### Task 8: Tabs in the store

**Files:**
- Modify: `Sources/LoreFeature/Store/LoreStore.swift`
- Test: `Tests/LoreFeatureTests/TabsTests.swift`

**Interfaces:**
- Consumes: `DocumentSession`, `VaultIndexCoordinator`.
- Produces on `LoreStore`: `private(set) var tabs: [DocumentSession]`, `var selectedTab: DocumentSession?`, `func open(_ row: IndexRow)`, `func open(url: URL)`, `func closeTab(_ session: DocumentSession)`, `func selectTab(_ session: DocumentSession)`, `private(set) var openError: (url: URL, error: Error)?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/TabsTests.swift`:

```swift
import XCTest
@testable import LoreFeature

@MainActor
final class TabsTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lore-tabs-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func makeStore(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    func test_openTwoDocuments_bothTabsStayOpen() throws {
        let root = tempDir(); let s = try makeStore(root)
        try "---\nid: a\ntitle: A\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "plain".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        s.open(url: root.appendingPathComponent("a.md"))
        s.open(url: root.appendingPathComponent("b.txt"))
        XCTAssertEqual(s.tabs.count, 2)
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "b.txt")
    }

    func test_openingSameDocumentTwice_selectsExistingTab() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        s.open(url: url)
        XCTAssertEqual(s.tabs.count, 1)
    }

    func test_closeTab_selectsNeighbor() throws {
        let root = tempDir(); let s = try makeStore(root)
        try "---\nid: a\ntitle: A\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "plain".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        s.open(url: root.appendingPathComponent("a.md"))
        s.open(url: root.appendingPathComponent("b.txt"))
        s.closeTab(s.selectedTab!)
        XCTAssertEqual(s.tabs.count, 1)
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "a.md")
    }

    func test_openUnsupportedType_recordsErrorWithoutOpeningTab() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("sheet.xlsx")
        try "binary".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        XCTAssertTrue(s.tabs.isEmpty)
        XCTAssertEqual(s.openError?.url, url)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "TabsTests|error:"`
Expected: FAIL — `value of type 'LoreStore' has no member 'tabs'`.

- [ ] **Step 3: Implement tabs on `LoreStore`**

```swift
    public private(set) var tabs: [DocumentSession] = []
    public private(set) var selectedTab: DocumentSession?
    /// Set when the last open attempt failed. The UI renders the fallback
    /// viewer from this rather than silently doing nothing — a file the list
    /// shows must always produce a visible response when clicked.
    public private(set) var openError: (url: URL, error: Error)?

    public func open(_ row: IndexRow) { open(url: row.path) }

    public func open(url: URL) {
        if let existing = tabs.first(where: { $0.url == url }) {
            selectedTab = existing
            return
        }
        do {
            let session = try DocumentSession.open(url: url, coordinator: coordinator)
            tabs.append(session)
            selectedTab = session
            openError = nil
        } catch {
            openError = (url, error)
        }
    }

    public func selectTab(_ session: DocumentSession) { selectedTab = session }

    public func closeTab(_ session: DocumentSession) {
        guard let idx = tabs.firstIndex(where: { $0 === session }) else { return }
        tabs.remove(at: idx)
        if selectedTab === session {
            selectedTab = tabs.indices.contains(idx) ? tabs[idx]
                        : tabs.indices.contains(idx - 1) ? tabs[idx - 1]
                        : tabs.last
        }
    }
```

`shutdown()` must also clear `tabs`, `selectedTab`, and `openError`.

- [ ] **Step 4: Run tests**

Run: `make test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Stage**

```bash
git add Sources/LoreFeature/Store/LoreStore.swift Tests/LoreFeatureTests/TabsTests.swift
```

---

### Task 9: Tab bar, document pane, and fallback viewer

**Files:**
- Create: `Sources/LoreFeature/Views/TabBarView.swift`
- Create: `Sources/LoreFeature/Views/DocumentPane.swift`
- Create: `Sources/LoreFeature/Documents/Fallback/FallbackViewer.swift`
- Modify: `Sources/LoreFeature/Views/LoreRootView.swift`
- Delete: `Sources/LoreFeature/Views/NoteEditorPane.swift` (its conflict UI moves to `DocumentPane`, its editing moves to `MarkdownDocumentEditor` from Task 3)
- Test: `Tests/LoreFeatureTests/RootViewSmokeTests.swift`

**Interfaces:**
- Consumes: `LoreStore.tabs/selectedTab/openError`, `DocumentSession`, `EditorContext`.
- Produces: `struct TabBarView: View`, `struct DocumentPane: View`, `struct FallbackViewer: View`.

- [ ] **Step 1: Write the failing smoke test**

Append to `Tests/LoreFeatureTests/RootViewSmokeTests.swift`, following the file's existing instantiation pattern:

```swift
@MainActor
func test_documentPane_buildsForEachOpenTab() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lore-view-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "---\nid: a\ntitle: A\n---\nx".write(
        to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    let store = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
    try store.setVaultRootForTesting(root)
    store.open(url: root.appendingPathComponent("a.md"))
    XCTAssertNotNil(store.selectedTab)
    _ = DocumentPane(store: store, session: store.selectedTab!, theme: HostTheme.preview)
    _ = TabBarView(store: store, theme: HostTheme.preview)
}
```

If `HostTheme.preview` does not exist in AinkradAppKit, use whatever theme value the existing `RootViewSmokeTests` already constructs — match the file, do not invent an API.

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "RootViewSmoke|error:"`
Expected: FAIL — `cannot find 'DocumentPane' in scope`.

- [ ] **Step 3: Create `FallbackViewer.swift`**

```swift
import SwiftUI
import AppKit
import AinkradAppKit

/// Shown when no engine claims a file, or when an engine's `load` threw.
///
/// The rule is degrade, never block: a vault containing `.xlsx` must not make
/// the file list lie about what is there, and a corrupt document must show a
/// reason rather than an empty editor the user might type into and "save".
struct FallbackViewer: View {
    let url: URL
    let error: Error?
    let theme: HostTheme

    var body: some View {
        AinkradEmptyState(
            icon: error == nil ? "doc.questionmark" : "exclamationmark.triangle",
            title: error == nil ? "Can't open this file yet" : "Couldn't open this file",
            message: message,
            actionTitle: "Reveal in Finder",
            action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        .background(theme.tokens.background)
    }

    private var message: String {
        if let error {
            return "\(url.lastPathComponent): \(error.localizedDescription)"
        }
        return "Lore has no editor for “\(url.lastPathComponent)” yet. "
             + "It stays in your vault and is safe to open elsewhere."
    }
}
```

- [ ] **Step 4: Create `DocumentPane.swift`**

```swift
import SwiftUI
import AinkradAppKit

/// Routes one session to its engine's editor, and owns the conflict banner
/// that is shared by every document type.
struct DocumentPane: View {
    @Bindable var store: LoreStore
    let session: DocumentSession
    let theme: HostTheme

    var body: some View {
        VStack(spacing: 0) {
            if session.conflict { conflictBanner }
            session.engine.makeEditor(
                EditorContext(theme: theme, onChange: { session.markChanged() }))
        }
        .background(theme.tokens.background)
    }

    /// Three resolutions, all reachable, none destructive by default. The old
    /// dialog offered only "load from disk" and treated dismissal as
    /// "overwrite", which meant the safe choice was the one you got by
    /// accident.
    private var conflictBanner: some View {
        HStack(spacing: AinkradSpacing.sm) {
            AinkradIconGlyph(systemName: "exclamationmark.triangle")
            Text("This document changed on disk outside Lore.")
                .frame(maxWidth: .infinity, alignment: .leading)
            AinkradButton(title: "Reload", style: .secondary) {
                try? session.resolveByReloading()
            }
            AinkradButton(title: "Save a copy", style: .secondary) {
                try? session.resolveBySavingCopy()
            }
            AinkradButton(title: "Overwrite", style: .ghost) {
                try? session.resolveByOverwriting()
            }
        }
        .padding(AinkradSpacing.sm)
        .background(theme.tokens.accentSecondary.opacity(0.15))
    }
}
```

- [ ] **Step 5: Create `TabBarView.swift`**

```swift
import SwiftUI
import AinkradAppKit

struct TabBarView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AinkradSpacing.xs) {
                ForEach(store.tabs, id: \.url) { session in
                    HStack(spacing: AinkradSpacing.xs) {
                        Text(session.title.isEmpty ? session.url.lastPathComponent : session.title)
                            .lineLimit(1)
                        if session.isDirty {
                            Circle().frame(width: 6, height: 6)
                                .foregroundStyle(theme.tokens.accentSecondary)
                        }
                        AinkradIconButton(systemName: "xmark") { store.closeTab(session) }
                    }
                    .padding(.horizontal, AinkradSpacing.sm)
                    .padding(.vertical, AinkradSpacing.xs)
                    .background(store.selectedTab === session
                                ? theme.tokens.accentSecondary.opacity(0.2) : .clear)
                    .onTapGesture { store.selectTab(session) }
                }
            }
            .padding(.horizontal, AinkradSpacing.sm)
        }
        .frame(height: 32)
    }
}
```

- [ ] **Step 6: Rewrite `LoreRootView`**

```swift
struct LoreRootView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @State private var query = ""
    @State private var selected: IndexRow?

    var body: some View {
        HStack(spacing: 0) {
            NoteListView(store: store, query: $query, selected: $selected, theme: theme,
                         onSelect: { row in selected = row; store.open(row) },
                         onNew: quickCapture)
                .frame(width: 280)
            VStack(spacing: 0) {
                if !store.tabs.isEmpty { TabBarView(store: store, theme: theme) }
                content
            }
        }
        .background(theme.tokens.background)
        .environment(\.ainkradTheme, theme.tokens)
    }

    @ViewBuilder private var content: some View {
        if let session = store.selectedTab {
            DocumentPane(store: store, session: session, theme: theme)
                .id(session.url)
        } else if let failure = store.openError {
            FallbackViewer(url: failure.url, error: failure.error, theme: theme)
        } else {
            AinkradEmptyState(
                icon: "book.closed",
                title: "No document open",
                message: "Select a document from the list, or press ⌘N to capture a new one.",
                actionTitle: "New note",
                action: quickCapture)
        }
    }

    private func quickCapture() {
        guard let note = try? store.create(title: "") else { return }
        store.open(url: note.path)
        selected = store.rows.first { $0.path == note.path }
    }
}
```

Add `⌘W` to close the selected tab by attaching `.keyboardShortcut("w", modifiers: .command)` to a hidden `Button` in `LoreRootView`, alongside the existing `⌘N` on the new-document button in `NoteListView`.

- [ ] **Step 7: Delete `NoteEditorPane.swift`**

```bash
git rm Sources/LoreFeature/Views/NoteEditorPane.swift
```

Its delete-note affordance moves to a context menu on the list row in `NoteListView` (`AinkradListRow` already supports `.contextMenu`), calling `store.delete(row)` then `store.closeTab` for any tab on that URL.

- [ ] **Step 8: Run tests**

Run: `make generate && make test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 9: Stage**

```bash
git add -A Sources/LoreFeature/Views Sources/LoreFeature/Documents Tests/LoreFeatureTests/RootViewSmokeTests.swift AinkradLore.xcodeproj
```

---

### Task 10: Keep the MCP surface working

M6 owns expanding the agent surface. This task only keeps it correct against the refactored store.

**Files:**
- Modify: `Sources/LoreFeature/MCP/LoreNoteOperations.swift`
- Test: `Tests/LoreFeatureTests/LoreNoteOperationsTests.swift`, `Tests/LoreFeatureTests/LoreMCPServerTests.swift`

**Interfaces:**
- Consumes: `LoreStore` facade (Tasks 6, 8), `IndexRow.type` (Task 5).
- Produces: no new public API. `LoreNoteOperations` continues to expose the same tool set with the same JSON shapes.

- [ ] **Step 1: Run the existing MCP tests to find the breakage**

Run: `make test 2>&1 | grep -E "MCP|NoteOperations|error:"`
Expected: compile errors or failures wherever `LoreNoteOperations` used APIs that moved.

- [ ] **Step 2: Write the failing test for the new behavior**

Append to `Tests/LoreFeatureTests/LoreNoteOperationsTests.swift`:

```swift
func test_search_onlyReturnsMarkdownNotes() async throws {
    let root = tempDir()
    try "---\nid: a\ntitle: A\n---\nneedle".write(
        to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try "needle in plain text".write(
        to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    let store = try makeStore(root)
    await store.settleForTesting()
    try store.rebuild()
    let ops = LoreNoteOperations(store: store)
    let result = await ops.run(#"{"tool":"search_notes","arguments":{"query":"needle"}}"#)
    XCTAssertTrue(result.contains("a.md"), result)
    XCTAssertFalse(result.contains("b.txt"),
                   "note tools must not claim plain-text files are notes")
}
```

Use whatever request-construction helper the existing tests in this file already use; match the file rather than inventing a JSON shape.

- [ ] **Step 3: Adapt `LoreNoteOperations`**

Two changes only:

1. Every read path that lists or searches filters `rows` to `row.type == MarkdownEngine.identifier`. The MCP tools are named `*_note` and documented as operating on notes; silently returning `.swift` files from `search_notes` would be the tool lying about its contract.
2. Any use of a `LoreStore` method that moved to `DocumentSession` (`load`, `save`) routes through the facade methods retained in Task 6 Step 4.

Do **not** add new tools here. M6 owns the expanded agent surface.

- [ ] **Step 4: Run tests**

Run: `make test 2>&1 | tail -40`
Expected: PASS, all MCP tests green.

- [ ] **Step 5: Stage**

```bash
git add Sources/LoreFeature/MCP Tests/LoreFeatureTests
```

---

### Task 11: Verify the M0 success criteria end to end

**Files:** none created; this task is verification and any small fixes it surfaces.

- [ ] **Step 1: Criterion 1 — no markdown assumptions in the shell**

Run:

```bash
grep -rn --include=*.swift -E '\.md\b|"md"|Frontmatter|\bNote\b' \
  Sources/LoreFeature/Store Sources/LoreFeature/Views
```

Expected: no hits outside `Sources/LoreFeature/Documents/` and the `create(title:)` note-capture path in `LoreStore` (which is markdown-specific by design in M0 — quick capture makes a markdown note). Anything else is a leak to fix.

- [ ] **Step 2: Criterion 2 — mixed vault**

Run `make sideload`, open Lore against a scratch folder containing a `.md`, a `.txt`, a `.swift`, a `.pdf`, and an `.xlsx`. Confirm: all five list; md/txt/swift open in editors; pdf and xlsx open the fallback viewer with a working *Reveal in Finder*; search finds text from the md, txt, and swift.

- [ ] **Step 3: Criterion 3 — property preservation on the real vault**

On a **copy** of the Ainkrad vault, open a note with pipeline frontmatter, type one character, wait for autosave, then:

```bash
diff <(git -C <vault-copy> show HEAD:<note-path>) <vault-copy>/<note-path>
```

Expected: only the `updated:` line and the typed character differ. Any dropped property is a Task 1 regression.

- [ ] **Step 4: Criterion 4 — independent tab state**

Open two documents, edit both without saving, externally modify one on disk. Confirm the conflict banner appears on that tab only and the other tab saves normally.

- [ ] **Step 5: Criteria 5 and 6 — tests and file sizes**

```bash
make test 2>&1 | tail -20
wc -l Sources/LoreFeature/**/*.swift | sort -rn | head -8
```

Expected: all tests pass; no file at or above 500 lines.

- [ ] **Step 6: Stop and report**

Do not commit. Write a report covering: what changed per task, the `make test` summary output, the results of each criterion above, and anything deferred or discovered. The human reviews before any commit.

---

## Self-Review Notes

Checked against the spec:

- **On-disk format** — `.lore` is specified but deliberately unimplemented; Task 4's engine set matches the spec's "markdown + plaintext only." Covered.
- **Engines** — Tasks 2–4. `IndexPayload.links` exists but is unpopulated, matching the spec's M1 boundary. Covered.
- **Component split** — Tasks 6–8. Covered.
- **Index generalization** — Task 5, including `user_version`. Covered.
- **Lossless frontmatter** — Task 1. Covered.
- **Shell/tabs** — Tasks 8–9, single window as specified. Covered.
- **Failure modes** — unclaimed type and load error in Task 9's `FallbackViewer` + Task 8's `openError`; conflict in Task 7 + Task 9's banner; index-write failure via `try?` in `DocumentSession.write`. Covered.
- **Testing** — conformance suite in Task 4; targeted tests across Tasks 1, 5, 7, 8, 9; regression gate in every task's test step. Covered.

**Known rough edge, recorded rather than hidden:** `DocumentSession.copyState` type-switches over the two concrete engines. It is the only shell-side engine knowledge in M0, and Task 7 Step 3 says explicitly that M3/M4 must replace it with a protocol requirement once a third engine makes the right shape obvious.
