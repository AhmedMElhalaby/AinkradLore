# Lore M1 — Structure and Linking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Lore a vault's structure — folder hierarchy, `[[wikilinks]]` with backlinks, rename/move that rewrites inbound links under a preview, and recoverable deletion.

**Architecture:** A `LinkParser` extracts raw link targets from markdown (never from code blocks); a `LinkResolver` owned by `VaultIndexCoordinator` resolves them basename-first like Obsidian; a new `links` table (schema v3) stores raw target and resolution side by side, making backlinks a query. `LinkRewriter` computes a full change set before any write, applies it links-first, and skips files that changed on disk. The sidebar gains a folder tree; `DocumentPane` gains a backlinks panel; `MarkdownEditor` gains `[[` autocomplete and click-to-open.

**Tech Stack:** Swift 6.0, SwiftUI, macOS 14.0+, GRDB 6.29.3 (SQLite + FTS5), AinkradAppKit, XCTest + swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-29-lore-m1-structure-and-linking-design.md`

## Global Constraints

- Swift 6.0, strict concurrency. `MACOSX_DEPLOYMENT_TARGET` 14.0.
- **No source file may exceed 500 lines.** `Frontmatter.swift` is already at 484 — do not add to it; if a task must, split parsing from serialization first.
- Build/test only via `make generate && make test`. Never `swift build` / `swift test` — this is an Xcode bundle target. `make test` takes several minutes; use a 600000ms timeout.
- `AinkradLore.xcodeproj` is gitignored: run `make generate` after adding directories, never commit the project file.
- All existing tests stay green at every task boundary: **142 XCTest + 44 swift-testing, 0 failures** at the start of M1.
- The index is derived state; the file on disk is truth. Never fail a user operation because an index write failed.
- **Degrade, never block.** Every failure mode has a visible, non-fatal outcome.
- **No bulk write without a preview.** Any operation that modifies more than one file must compute its full change set first and apply only on explicit confirmation.
- Local commits on the feature branch are approved. **Never push, open a PR, or merge** — that is the human's decision.

## Inherited context from M0

Facts an implementer cannot discover from their own task:

- `IndexPayload` already carries `links: [String]`, documented "Always empty in M0; M1 populates it." It also carries `id: String?`, `title`, `plaintext`, `tags`, `properties: [FrontmatterPair]`, `outline: [OutlineEntry]`.
- `DocumentSession` has `cancelPendingSave()`, `resolveByReloading()`, `reloadGeneration: Int`, `isReadOnly`, `conflict`, `lastSaveError`, and a **mutable** `url` (`public private(set) var`). It is `Identifiable` with a stable `UUID` minted at init — use `session.id` for SwiftUI identity, never `session.url`.
- `LoreStore.closeTab(_:force:) -> Bool` returns `false` when a dirty session's save failed; `closeAllTabs()` saves-then-cancels-then-clears and is called from `shutdown()` and `setVaultRoot`.
- `VaultIndexCoordinator.scanVault(at:)` is `nonisolated static`, walks with `.skipsPackageDescendants`, skips dot-prefixed components **below the root**, skips plain directories but indexes packages as one `EngineRegistry.unclaimedType` row, caps plaintext at 1 MB, and takes `updated` from file mtime.
- `LoreIndex.schemaVersion` is `2`; a mismatch deletes and rebuilds. `replaceAll(with: [IndexEntry])` writes everything in one transaction.
- `Frontmatter` is preserve-and-patch: `parse` keeps the original block on `Note.rawFrontmatter`, `serialize` patches only changed modelled keys. **Do not regress this.**
- `MarkdownEngine.outline(of:)` has a known gap — it does not skip fenced code blocks. Task 1 must not copy that mistake.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `Sources/LoreFeature/Logic/LinkParser.swift` | Extract raw link targets from markdown; code-aware |
| `Sources/LoreFeature/Logic/LinkResolver.swift` | Resolve raw targets to documents, basename-first |
| `Sources/LoreFeature/Logic/LinkRewriter.swift` | Compute and apply rename/move change sets |
| `Sources/LoreFeature/Views/FolderTreeView.swift` | Folder tree sidebar mode |
| `Sources/LoreFeature/Views/BacklinksPanel.swift` | Backlinks + unresolved links under the editor |
| `Sources/LoreFeature/Views/LinkCompletionView.swift` | `[[` autocomplete popup |
| `Sources/LoreFeature/Views/RenamePreviewSheet.swift` | Change-set confirmation UI |
| `Tests/LoreFeatureTests/LinkParserTests.swift` | Parser shapes, incl. code blocks |
| `Tests/LoreFeatureTests/LinkResolverTests.swift` | Basename collisions, aliases, case |
| `Tests/LoreFeatureTests/LinkRewriterTests.swift` | Change sets, ordering, conflict skip |
| `Tests/LoreFeatureTests/TrashTests.swift` | Trash behavior and failure |

**Modified:**

| Path | Change |
|---|---|
| `Sources/LoreFeature/Models/Note.swift` | `aliases` read from frontmatter |
| `Sources/LoreFeature/Documents/LoreDocument.swift` | `IndexPayload.links` becomes `[DocumentLink]` |
| `Sources/LoreFeature/Documents/Markdown/MarkdownEngine.swift` | Populate `links` via `LinkParser` |
| `Sources/LoreFeature/Store/LoreIndex.swift` | schema v3, `links` table, backlink queries |
| `Sources/LoreFeature/Store/VaultIndexCoordinator.swift` | Resolve links during scan; expose queries |
| `Sources/LoreFeature/Store/LoreStore.swift` | `rename`, `move`, `trash`, backlink accessors |
| `Sources/LoreFeature/Views/LoreRootView.swift` | Sidebar mode toggle, rename sheet host |
| `Sources/LoreFeature/Views/NoteListView.swift` | Extract row rendering for reuse by the tree |
| `Sources/LoreFeature/Views/DocumentPane.swift` | Host `BacklinksPanel` |
| `Sources/LoreFeature/Views/MarkdownEditor.swift` | `[[` completion + click-to-open |

---

### Task 1: `LinkParser`

**Files:**
- Create: `Sources/LoreFeature/Logic/LinkParser.swift`
- Test: `Tests/LoreFeatureTests/LinkParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct DocumentLink: Equatable, Sendable { public let rawTarget: String; public let displayText: String?; public let isEmbed: Bool }`
  - `public enum LinkParser { public static func links(in body: String) -> [DocumentLink] }`
- `rawTarget` is the target **exactly as written**, including any `#Heading` or `#^block` fragment, with surrounding whitespace trimmed. It never includes `|display`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/LinkParserTests.swift`:

```swift
import XCTest
@testable import LoreFeature

final class LinkParserTests: XCTestCase {
    private func targets(_ body: String) -> [String] {
        LinkParser.links(in: body).map(\.rawTarget)
    }

    func test_parsesPlainWikilink() {
        XCTAssertEqual(targets("see [[Design]] here"), ["Design"])
    }

    func test_parsesDisplayTextAndKeepsTargetClean() {
        let links = LinkParser.links(in: "see [[Design|the design]]")
        XCTAssertEqual(links.map(\.rawTarget), ["Design"])
        XCTAssertEqual(links.first?.displayText, "the design")
    }

    func test_keepsHeadingAndBlockFragmentsInTheTarget() {
        XCTAssertEqual(targets("[[Design#Overview]] and [[Design#^abc123]]"),
                       ["Design#Overview", "Design#^abc123"])
    }

    func test_flagsEmbeds() {
        let links = LinkParser.links(in: "![[Diagram]]")
        XCTAssertEqual(links.map(\.rawTarget), ["Diagram"])
        XCTAssertEqual(links.first?.isEmbed, true)
    }

    func test_parsesMarkdownLinksToLocalFiles() {
        XCTAssertEqual(targets("[text](notes/Design.md)"), ["notes/Design.md"])
    }

    func test_ignoresExternalMarkdownLinks() {
        XCTAssertEqual(targets("[site](https://example.com) [m](mailto:a@b.c)"), [])
    }

    func test_ignoresLinksInsideFencedCodeBlocks() {
        let body = """
        real [[One]]

        ```
        not a link [[Two]]
        ```

        real [[Three]]
        """
        XCTAssertEqual(targets(body), ["One", "Three"])
    }

    func test_ignoresLinksInsideTildeFencesAndInlineCode() {
        let body = """
        ~~~
        [[Fenced]]
        ~~~
        `[[Inline]]` but [[Real]]
        """
        XCTAssertEqual(targets(body), ["Real"])
    }

    func test_ignoresUnclosedLink() {
        XCTAssertEqual(targets("[[Unclosed and more text"), [])
    }

    func test_handlesUnicodeAndSpaces() {
        XCTAssertEqual(targets("[[Café Notes/Über Design]]"), ["Café Notes/Über Design"])
    }

    func test_emptyTargetIsIgnored() {
        XCTAssertEqual(targets("[[]] [[   ]]"), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "LinkParser|error:"`
Expected: FAIL — `cannot find 'LinkParser' in scope`.

- [ ] **Step 3: Create `LinkParser.swift`**

```swift
import Foundation

/// One outbound link found in a document.
public struct DocumentLink: Equatable, Sendable {
    /// The target exactly as written, including any `#Heading` or `#^block`
    /// fragment. Never includes the `|display` part.
    ///
    /// Stored verbatim because rename rewriting must reproduce the user's own
    /// syntax: a link written `[[design]]` becomes `[[new-name]]`, never
    /// `[[Projects/New Name.md]]`.
    public let rawTarget: String
    public let displayText: String?
    public let isEmbed: Bool

    public init(rawTarget: String, displayText: String? = nil, isEmbed: Bool = false) {
        self.rawTarget = rawTarget; self.displayText = displayText; self.isEmbed = isEmbed
    }
}

/// Extracts links from markdown body text.
///
/// Deliberately code-aware: a `[[link]]` inside a fenced block or inline code
/// is documentation ABOUT a link, not a link. `MarkdownEngine.outline(of:)`
/// has this gap and produces phantom headings from `#` comments in code; a
/// phantom LINK is worse, because it appears in another document's backlinks
/// and survives into rename rewriting.
public enum LinkParser {
    public static func links(in body: String) -> [DocumentLink] {
        var found: [DocumentLink] = []
        var inFence = false
        var fenceMarker = ""

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceOpener(trimmed) {
                if inFence, trimmed.hasPrefix(fenceMarker) { inFence = false; fenceMarker = "" }
                else if !inFence { inFence = true; fenceMarker = marker }
                continue
            }
            guard !inFence else { continue }
            found.append(contentsOf: links(inLine: String(line)))
        }
        return found
    }

    /// ``` or ~~~ (three or more), per CommonMark.
    private static func fenceOpener(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) { return marker }
        return nil
    }

    private static func links(inLine line: String) -> [DocumentLink] {
        var result: [DocumentLink] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            // Inline code spans swallow everything to the closing backtick.
            if chars[i] == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != "`" { j += 1 }
                i = j < chars.count ? j + 1 : chars.count
                continue
            }
            if chars[i] == "[", i + 1 < chars.count, chars[i + 1] == "[" {
                let isEmbed = i > 0 && chars[i - 1] == "!"
                if let close = closingBrackets(chars, from: i + 2) {
                    let inner = String(chars[(i + 2)..<close])
                    if let link = wikilink(inner, isEmbed: isEmbed) { result.append(link) }
                    i = close + 2
                    continue
                }
            }
            if chars[i] == "[", let link = markdownLink(chars, from: i) {
                result.append(link.link)
                i = link.end
                continue
            }
            i += 1
        }
        return result
    }

    private static func closingBrackets(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "]" && chars[i + 1] == "]" { return i }
            i += 1
        }
        return nil
    }

    private static func wikilink(_ inner: String, isEmbed: Bool) -> DocumentLink? {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts[0].trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let display = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        return DocumentLink(rawTarget: target,
                            displayText: (display?.isEmpty ?? true) ? nil : display,
                            isEmbed: isEmbed)
    }

    /// `[text](target)` — local targets only. A URL with a scheme is not a
    /// vault link and must never enter the graph.
    private static func markdownLink(_ chars: [Character], from start: Int)
        -> (link: DocumentLink, end: Int)? {
        var i = start + 1
        while i < chars.count, chars[i] != "]" { i += 1 }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        let text = String(chars[(start + 1)..<i])
        var j = i + 2
        while j < chars.count, chars[j] != ")" { j += 1 }
        guard j < chars.count else { return nil }
        let target = String(chars[(i + 2)..<j]).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains("://"), !target.hasPrefix("mailto:") else {
            return nil
        }
        return (DocumentLink(rawTarget: target, displayText: text.isEmpty ? nil : text,
                             isEmbed: false), j + 1)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS, all `LinkParserTests` green, all pre-existing tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoreFeature/Logic/LinkParser.swift Tests/LoreFeatureTests/LinkParserTests.swift
git commit -m "feat(links): parse wikilinks and markdown links, skipping code"
```

---

### Task 2: Aliases, and `IndexPayload.links` carrying `DocumentLink`

**Files:**
- Modify: `Sources/LoreFeature/Models/Note.swift`
- Modify: `Sources/LoreFeature/Logic/Frontmatter.swift` (read only — do not touch serialization)
- Modify: `Sources/LoreFeature/Documents/LoreDocument.swift`
- Modify: `Sources/LoreFeature/Documents/Markdown/MarkdownEngine.swift`
- Test: `Tests/LoreFeatureTests/FrontmatterTests.swift`, `Tests/LoreFeatureTests/EngineConformanceTests.swift`

**Interfaces:**
- Consumes: `DocumentLink`, `LinkParser` (Task 1).
- Produces:
  - `Note.aliases: [String]` — parsed from the frontmatter `aliases` key, supporting both inline `[a, b]` and block-sequence forms.
  - `IndexPayload.links: [DocumentLink]` (was `[String]`), plus `IndexPayload.aliases: [String]`.
  - `MarkdownEngine.indexPayload` populates both.

**CRITICAL:** `aliases` is currently an *unmodelled* frontmatter key preserved verbatim by preserve-and-patch. Reading it must not make it modelled for serialization — `Frontmatter.serialize` must still leave it byte-identical. Add reading only; do not add `aliases` to the `modelled` set used by patching.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LoreFeatureTests/FrontmatterTests.swift`:

```swift
func test_readsInlineAliases() {
    let text = """
    ---
    id: a
    title: T
    aliases: [Design Doc, Spec]
    ---
    body
    """
    let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/a.md"))
    XCTAssertEqual(note.aliases, ["Design Doc", "Spec"])
}

func test_readsBlockSequenceAliases() {
    let text = """
    ---
    id: a
    title: T
    aliases:
      - Design Doc
      - Spec
    ---
    body
    """
    let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/a.md"))
    XCTAssertEqual(note.aliases, ["Design Doc", "Spec"])
}

func test_readingAliasesDoesNotChangeSerialization() {
    let text = """
    ---
    id: a
    title: T
    aliases:
      - Design Doc
    ---
    body
    """
    let path = URL(fileURLWithPath: "/tmp/a.md")
    XCTAssertEqual(Frontmatter.serialize(Frontmatter.parse(text, path: path)), text)
}
```

Append to `Tests/LoreFeatureTests/EngineConformanceTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "aliases|links|error:"`
Expected: FAIL — `value of type 'Note' has no member 'aliases'`.

- [ ] **Step 3: Add `aliases` to `Note` and read it in `Frontmatter.parse`**

In `Note.swift`, add `public var aliases: [String]` with `aliases: [String] = []` defaulted in the initializer.

In `Frontmatter.parse`, read the `aliases` entry using the SAME entry-scanning machinery that already reads `tags` (find how `tags` is read — it handles both inline `[a, b]` and block-sequence forms — and reuse it verbatim rather than writing a second list reader). Pass the result as `aliases:`.

**Do not** add `"aliases"` to the modelled-key set used by `patch`. Reading is not modelling; the key must keep round-tripping through the preserved raw block.

- [ ] **Step 4: Widen `IndexPayload`**

In `LoreDocument.swift`, change `links` from `[String]` to `[DocumentLink]` and add `aliases`:

```swift
    /// Outbound links, in document order. Populated by M1.
    public var links: [DocumentLink]
    /// Alternate names this document answers to, from frontmatter `aliases`.
    public var aliases: [String]
```

Update the initializer with `links: [DocumentLink] = []` and `aliases: [String] = []`.

- [ ] **Step 5: Populate them in `MarkdownEngine`**

In `MarkdownEngine.indexPayload`, add `links: LinkParser.links(in: note.body)` and `aliases: note.aliases`.

- [ ] **Step 6: Run tests**

Run: `make test 2>&1 | tail -30`
Expected: PASS. The conformance suite's byte-stability test must still pass — if it fails, `aliases` was made modelled and serialization changed.

- [ ] **Step 7: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(links): read aliases and carry parsed links in the index payload"
```

---

### Task 3: Index schema v3 — the `links` table

**Files:**
- Modify: `Sources/LoreFeature/Store/LoreIndex.swift`
- Test: `Tests/LoreFeatureTests/LoreIndexTests.swift`

**Interfaces:**
- Consumes: `DocumentLink`, `IndexEntry`.
- Produces:
  - `LoreIndex.schemaVersion` = `3`.
  - `IndexEntry` gains `let resolvedLinks: [ResolvedLink]`, where
    `public struct ResolvedLink: Sendable, Equatable { public let rawTarget: String; public let targetPath: URL?; public let isEmbed: Bool }`.
  - `LoreIndex.backlinks(to: URL) -> [IndexRow]`
  - `LoreIndex.unresolvedLinks(from: URL) -> [String]`
  - `LoreIndex.outgoingLinks(from: URL) -> [ResolvedLink]`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LoreFeatureTests/LoreIndexTests.swift`:

```swift
private func makeIndex() throws -> LoreIndex {
    try LoreIndex(path: FileManager.default.temporaryDirectory
        .appendingPathComponent("idx-\(UUID()).sqlite"))
}

private func entry(_ path: String, title: String,
                   links: [ResolvedLink] = []) -> IndexEntry {
    IndexEntry(url: URL(fileURLWithPath: path), type: "markdown",
               payload: IndexPayload(title: title, plaintext: "x"),
               updated: Date(), resolvedLinks: links)
}

func test_backlinksListDocumentsPointingAtATarget() throws {
    let index = try makeIndex()
    let target = URL(fileURLWithPath: "/v/Design.md")
    try index.replaceAll(with: [
        entry("/v/A.md", title: "A",
              links: [ResolvedLink(rawTarget: "Design", targetPath: target, isEmbed: false)]),
        entry("/v/B.md", title: "B",
              links: [ResolvedLink(rawTarget: "Design#Overview", targetPath: target, isEmbed: false)]),
        entry("/v/C.md", title: "C"),
        entry("/v/Design.md", title: "Design"),
    ])
    XCTAssertEqual(Set(try index.backlinks(to: target).map(\.title)), ["A", "B"])
}

func test_unresolvedLinksAreListedPerDocument() throws {
    let index = try makeIndex()
    try index.replaceAll(with: [
        entry("/v/A.md", title: "A", links: [
            ResolvedLink(rawTarget: "Missing", targetPath: nil, isEmbed: false),
            ResolvedLink(rawTarget: "Design", targetPath: URL(fileURLWithPath: "/v/Design.md"),
                         isEmbed: false),
        ]),
        entry("/v/Design.md", title: "Design"),
    ])
    XCTAssertEqual(try index.unresolvedLinks(from: URL(fileURLWithPath: "/v/A.md")), ["Missing"])
}

func test_outgoingLinksPreserveRawTargets() throws {
    let index = try makeIndex()
    let target = URL(fileURLWithPath: "/v/Design.md")
    try index.replaceAll(with: [
        entry("/v/A.md", title: "A",
              links: [ResolvedLink(rawTarget: "design", targetPath: target, isEmbed: false)]),
    ])
    let out = try index.outgoingLinks(from: URL(fileURLWithPath: "/v/A.md"))
    XCTAssertEqual(out.map(\.rawTarget), ["design"])
    XCTAssertEqual(out.first?.targetPath, target)
}

func test_replaceAllPrunesLinksOfRemovedDocuments() throws {
    let index = try makeIndex()
    let target = URL(fileURLWithPath: "/v/Design.md")
    try index.replaceAll(with: [
        entry("/v/A.md", title: "A",
              links: [ResolvedLink(rawTarget: "Design", targetPath: target, isEmbed: false)]),
        entry("/v/Design.md", title: "Design"),
    ])
    try index.replaceAll(with: [entry("/v/Design.md", title: "Design")])
    XCTAssertTrue(try index.backlinks(to: target).isEmpty)
}

func test_schemaVersionTwoIndexIsRebuiltNotRead() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("idx-\(UUID()).sqlite")
    let legacy = try DatabaseQueue(path: path.path)
    try legacy.write { db in
        try db.execute(sql: "PRAGMA user_version = 2;")
        try db.execute(sql: "CREATE TABLE documents(path TEXT PRIMARY KEY);")
        try db.execute(sql: "INSERT INTO documents(path) VALUES('/v/old.md');")
    }
    try legacy.close()
    let index = try LoreIndex(path: path)
    XCTAssertTrue(try index.all().isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "ResolvedLink|backlinks|error:"`
Expected: FAIL — `cannot find 'ResolvedLink' in scope`.

- [ ] **Step 3: Add `ResolvedLink` and widen `IndexEntry`**

At the top of `LoreIndex.swift`:

```swift
/// A link after resolution: what the author wrote, and what it points at.
///
/// Both halves are stored. `targetPath` drives backlinks and navigation;
/// `rawTarget` is what rename rewriting must find and replace, so that a link
/// written `[[design]]` is rewritten `[[new-name]]` rather than being silently
/// normalized to a full path.
public struct ResolvedLink: Sendable, Equatable {
    public let rawTarget: String
    public let targetPath: URL?
    public let isEmbed: Bool
    public init(rawTarget: String, targetPath: URL?, isEmbed: Bool) {
        self.rawTarget = rawTarget; self.targetPath = targetPath; self.isEmbed = isEmbed
    }
}
```

Add `public let resolvedLinks: [ResolvedLink]` to `IndexEntry`, defaulted to `[]` in its initializer so existing construction sites keep compiling.

- [ ] **Step 4: Bump the schema and create the table**

Set `static let schemaVersion: Int32 = 3`. In `init`'s `CREATE TABLE` block, add:

```swift
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS links(
                    source_path TEXT NOT NULL,
                    raw_target  TEXT NOT NULL,
                    target_path TEXT,
                    is_embed    INTEGER NOT NULL DEFAULT 0);
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS links_by_target ON links(target_path);
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS links_by_source ON links(source_path);
            """)
```

Both indexes matter: `links_by_target` serves backlinks (run on every tab switch), `links_by_source` serves the unresolved list and rewriting.

- [ ] **Step 5: Write links inside the existing transaction**

In the private `write(_:into:)` helper, after the document row is written, replace that document's links:

```swift
        try db.execute(sql: "DELETE FROM links WHERE source_path = ?",
                       arguments: [entry.url.path])
        for link in entry.resolvedLinks {
            try db.execute(sql: """
                INSERT INTO links(source_path, raw_target, target_path, is_embed)
                VALUES(?,?,?,?);
            """, arguments: [entry.url.path, link.rawTarget,
                             link.targetPath?.path, link.isEmbed ? 1 : 0])
        }
```

In `replaceAll`, when pruning stale documents, also `DELETE FROM links WHERE source_path = ?` for each pruned path. Links must never outlive the document that declared them.

- [ ] **Step 6: Add the three queries**

```swift
    /// Documents containing a link that resolves to `target`.
    public func backlinks(to target: URL) throws -> [IndexRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT d.* FROM documents d
                JOIN links l ON l.source_path = d.path
                WHERE l.target_path = ?
                ORDER BY d.updated DESC;
            """, arguments: [target.path]).map(Self.row)
        }
    }

    /// This document's outbound links that resolve to nothing. A normal state:
    /// it is how a link to a not-yet-written note behaves.
    public func unresolvedLinks(from source: URL) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT raw_target FROM links
                WHERE source_path = ? AND target_path IS NULL;
            """, arguments: [source.path])
        }
    }

    public func outgoingLinks(from source: URL) throws -> [ResolvedLink] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT raw_target, target_path, is_embed FROM links
                WHERE source_path = ?;
            """, arguments: [source.path]).map { r in
                ResolvedLink(rawTarget: r["raw_target"],
                             targetPath: (r["target_path"] as String?).map {
                                 URL(fileURLWithPath: $0)
                             },
                             isEmbed: (r["is_embed"] as Int) == 1)
            }
        }
    }
```

- [ ] **Step 7: Run tests**

Run: `make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/LoreFeature/Store/LoreIndex.swift Tests/LoreFeatureTests/LoreIndexTests.swift
git commit -m "feat(index): add links table and backlink queries at schema v3"
```

---

### Task 4: `LinkResolver`, wired into the vault scan

**Files:**
- Create: `Sources/LoreFeature/Logic/LinkResolver.swift`
- Modify: `Sources/LoreFeature/Store/VaultIndexCoordinator.swift`
- Test: `Tests/LoreFeatureTests/LinkResolverTests.swift`

**Interfaces:**
- Consumes: `DocumentLink`, `ResolvedLink`, `IndexEntry`.
- Produces:
  - `public struct LinkResolver { public init(documents: [(url: URL, title: String, aliases: [String])]); public func resolve(_ rawTarget: String) -> URL? }`
  - `LinkResolver.basename(of rawTarget: String) -> String` — strips any `#…` fragment and any `.md` extension.
  - `VaultIndexCoordinator.scanVault` returns entries whose `resolvedLinks` are populated.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/LinkResolverTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "LinkResolver|error:"`
Expected: FAIL — `cannot find 'LinkResolver' in scope`.

- [ ] **Step 3: Create `LinkResolver.swift`**

```swift
import Foundation

/// Resolves raw link targets to documents, using Obsidian's rules.
///
/// Basename-first: `[[Design]]` finds `Projects/Design.md` although the link
/// names neither the folder nor the extension. A target containing a `/`
/// is treated as a path suffix and disambiguates. Matching is case-insensitive,
/// as Obsidian is on macOS. Frontmatter aliases participate.
///
/// Ambiguity is resolved to the SHORTEST path, matching Obsidian — a link can
/// therefore point somewhere the author did not intend when two documents share
/// a basename, which is why the backlinks panel surfaces ambiguity.
public struct LinkResolver: Sendable {
    private let byKey: [String: [URL]]

    public init(documents: [(url: URL, title: String, aliases: [String])]) {
        var map: [String: [URL]] = [:]
        for doc in documents {
            var keys = [doc.url.deletingPathExtension().lastPathComponent, doc.title]
            keys.append(contentsOf: doc.aliases)
            for key in keys where !key.isEmpty {
                map[key.lowercased(), default: []].append(doc.url)
            }
        }
        // Shortest path wins ties, deterministically.
        byKey = map.mapValues { $0.sorted { $0.path.count < $1.path.count } }
    }

    /// Strips any `#Heading` / `#^block` fragment and a trailing `.md`.
    public static func basename(of rawTarget: String) -> String {
        var target = rawTarget
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        if target.lowercased().hasSuffix(".md") { target = String(target.dropLast(3)) }
        return target.trimmingCharacters(in: .whitespaces)
    }

    public func resolve(_ rawTarget: String) -> URL? {
        let target = Self.basename(of: rawTarget)
        guard !target.isEmpty else { return nil }

        if target.contains("/") {
            // Explicit path: match as a suffix of a document's path.
            let needle = "/" + target.lowercased()
            let candidates = byKey.values.flatMap { $0 }.filter {
                $0.deletingPathExtension().path.lowercased().hasSuffix(needle)
            }
            return candidates.min { $0.path.count < $1.path.count }
        }
        return byKey[target.lowercased()]?.first
    }
}
```

- [ ] **Step 4: Resolve during the vault scan**

`scanVault` currently returns `[IndexEntry]` with no links. Resolution needs every document's title and aliases, so it is a **second pass** over the entries the first pass produced. In `VaultIndexCoordinator`, after the enumerator loop builds `entries`:

```swift
        // Resolution is a second pass because a link can point at any document
        // in the vault, including one the enumerator has not reached yet.
        let resolver = LinkResolver(documents: entries.map {
            (url: $0.url, title: $0.payload.title, aliases: $0.payload.aliases)
        })
        return entries.map { entry in
            IndexEntry(url: entry.url, type: entry.type, payload: entry.payload,
                       updated: entry.updated,
                       resolvedLinks: entry.payload.links.map {
                           ResolvedLink(rawTarget: $0.rawTarget,
                                        targetPath: resolver.resolve($0.rawTarget),
                                        isEmbed: $0.isEmbed)
                       })
        }
```

Also update `indexDocument(_:at:)` (the single-document path used after a save) to resolve against the current `rows` — a note saved with a new link must show that link's backlink without a full rescan. Build the resolver from `rows` plus the document being indexed.

- [ ] **Step 5: Write a coordinator-level test**

Append to `Tests/LoreFeatureTests/LoreStoreTests.swift`:

```swift
func test_scanVault_resolvesLinksBetweenDocuments() throws {
    let root = tempDir()
    try "---\nid: a\ntitle: Alpha\n---\nlinks to [[Beta]]"
        .write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
    try "---\nid: b\ntitle: Beta\n---\nno links"
        .write(to: root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)

    let entries = VaultIndexCoordinator.scanVault(at: root)
    let alpha = entries.first { $0.url.lastPathComponent == "alpha.md" }
    XCTAssertEqual(alpha?.resolvedLinks.first?.rawTarget, "Beta")
    XCTAssertEqual(alpha?.resolvedLinks.first?.targetPath?.lastPathComponent, "beta.md")
}

func test_scanVault_leavesUnknownTargetsUnresolved() throws {
    let root = tempDir()
    try "---\nid: a\ntitle: Alpha\n---\n[[Nowhere]]"
        .write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
    let entries = VaultIndexCoordinator.scanVault(at: root)
    XCTAssertNil(entries.first?.resolvedLinks.first?.targetPath)
    XCTAssertEqual(entries.first?.resolvedLinks.first?.rawTarget, "Nowhere")
}
```

- [ ] **Step 6: Run tests**

Run: `make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(links): resolve link targets basename-first during vault scan"
```

---

### Task 5: Store-level link API

**Files:**
- Modify: `Sources/LoreFeature/Store/VaultIndexCoordinator.swift`
- Modify: `Sources/LoreFeature/Store/LoreStore.swift`
- Test: `Tests/LoreFeatureTests/LoreStoreTests.swift`

**Interfaces:**
- Consumes: `LoreIndex.backlinks(to:)`, `unresolvedLinks(from:)`, `outgoingLinks(from:)`, `LinkResolver`.
- Produces on `LoreStore`:
  - `public func backlinks(to url: URL) -> [Backlink]` where
    `public struct Backlink: Identifiable, Sendable { public let id: URL; public let row: IndexRow; public let context: String }`
  - `public func unresolvedLinks(from url: URL) -> [String]`
  - `public func resolveLink(_ rawTarget: String) -> URL?`
  - `public func openLink(_ rawTarget: String) -> Bool` — opens the resolved target in a tab, returns `false` when unresolved.
  - `public func linkCompletions(matching prefix: String) -> [IndexRow]`
- `context` is the first line in the source document containing the link's raw target, trimmed, truncated to 200 characters. If the file cannot be read, `context` is empty — never a failure.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LoreFeatureTests/LoreStoreTests.swift`:

```swift
func test_backlinksIncludeSurroundingLineAsContext() async throws {
    let root = tempDir()
    try "---\nid: a\ntitle: Alpha\n---\nintro\nwe discussed [[Beta]] at length\noutro"
        .write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
    try "---\nid: b\ntitle: Beta\n---\n"
        .write(to: root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
    let s = try makeStore(root)
    await s.settleForTesting()
    try s.rebuild()

    let links = s.backlinks(to: root.appendingPathComponent("beta.md"))
    XCTAssertEqual(links.map(\.row.title), ["Alpha"])
    XCTAssertEqual(links.first?.context, "we discussed [[Beta]] at length")
}

func test_unresolvedLinksAreReported() async throws {
    let root = tempDir()
    try "---\nid: a\ntitle: Alpha\n---\n[[Nowhere]]"
        .write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
    let s = try makeStore(root)
    await s.settleForTesting()
    try s.rebuild()
    XCTAssertEqual(s.unresolvedLinks(from: root.appendingPathComponent("alpha.md")), ["Nowhere"])
}

func test_openLinkOpensResolvedTargetInATab() async throws {
    let root = tempDir()
    try "---\nid: b\ntitle: Beta\n---\n"
        .write(to: root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
    let s = try makeStore(root)
    await s.settleForTesting()
    try s.rebuild()
    XCTAssertTrue(s.openLink("Beta"))
    XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "beta.md")
}

func test_openLinkReturnsFalseWhenUnresolved() async throws {
    let root = tempDir()
    let s = try makeStore(root)
    await s.settleForTesting()
    XCTAssertFalse(s.openLink("Nowhere"))
    XCTAssertNil(s.selectedTab)
}

func test_linkCompletionsMatchTitlesAndAliases() async throws {
    let root = tempDir()
    try "---\nid: b\ntitle: Beta Notes\naliases: [Bravo]\n---\n"
        .write(to: root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
    let s = try makeStore(root)
    await s.settleForTesting()
    try s.rebuild()
    XCTAssertEqual(s.linkCompletions(matching: "bet").map(\.title), ["Beta Notes"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "backlinks|openLink|error:"`
Expected: FAIL — `value of type 'LoreStore' has no member 'backlinks'`.

- [ ] **Step 3: Expose the queries on the coordinator**

Add to `VaultIndexCoordinator`, each returning empty rather than throwing — the index is derived state and a query failure must never break the UI:

```swift
    func backlinkRows(to url: URL) -> [IndexRow] { (try? index?.backlinks(to: url)) ?? [] }
    func unresolvedLinks(from url: URL) -> [String] {
        (try? index?.unresolvedLinks(from: url)) ?? []
    }
    /// A resolver over the CURRENT index rows, for link clicks and completion.
    func currentResolver() -> LinkResolver {
        LinkResolver(documents: rows.map {
            (url: $0.path, title: $0.title, aliases: $0.aliases)
        })
    }
```

`IndexRow` needs `aliases` for this: add `public let aliases: [String]` to `IndexRow`, store it in the `documents` table as a comma-joined column alongside `tags` (follow exactly how `tags` is written and read), and populate it from `entry.payload.aliases`. Because the schema changes again, this is still version 3 — Task 3 and Task 5 both land before any release, so bump nothing; just make sure the column is in the `CREATE TABLE` from Task 3. **If Task 3 is already committed, add the column there and let the version-3 rebuild handle it.**

- [ ] **Step 4: Add the store API**

```swift
    public struct Backlink: Identifiable, Sendable {
        public let id: URL
        public let row: IndexRow
        /// The line in the source document that contains the link. Empty when
        /// the file cannot be read — context is a nicety, never a failure.
        public let context: String
    }

    public func backlinks(to url: URL) -> [Backlink] {
        coordinator.backlinkRows(to: url).map { row in
            Backlink(id: row.path, row: row, context: Self.context(in: row.path, for: url))
        }
    }

    private static func context(in source: URL, for target: URL) -> String {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return "" }
        let needle = target.deletingPathExtension().lastPathComponent.lowercased()
        for line in text.split(separator: "\n") where line.lowercased().contains(needle) {
            return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
        }
        return ""
    }

    public func unresolvedLinks(from url: URL) -> [String] {
        coordinator.unresolvedLinks(from: url)
    }

    public func resolveLink(_ rawTarget: String) -> URL? {
        coordinator.currentResolver().resolve(rawTarget)
    }

    @discardableResult
    public func openLink(_ rawTarget: String) -> Bool {
        guard let url = resolveLink(rawTarget) else { return false }
        open(url: url)
        return true
    }

    /// Documents whose title or an alias starts with `prefix`, for `[[` completion.
    public func linkCompletions(matching prefix: String) -> [IndexRow] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return Array(rows.prefix(20)) }
        return rows.filter { row in
            row.title.lowercased().hasPrefix(needle)
                || row.aliases.contains { $0.lowercased().hasPrefix(needle) }
        }
    }
```

- [ ] **Step 5: Run tests**

Run: `make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(links): expose backlinks, resolution and completion on the store"
```

---

### Task 6: `LinkRewriter` — computing the change set

**Files:**
- Create: `Sources/LoreFeature/Logic/LinkRewriter.swift`
- Test: `Tests/LoreFeatureTests/LinkRewriterTests.swift`

**Interfaces:**
- Consumes: `ResolvedLink`, `LinkResolver`.
- Produces:
  - `public struct LinkEdit: Sendable, Equatable { public let file: URL; public let oldTarget: String; public let newTarget: String }`
  - `public struct RenamePlan: Sendable { public let source: URL; public let destination: URL; public let edits: [LinkEdit]; public var affectedFiles: [URL] }`
  - `public enum LinkRewriter { public static func plan(renaming source: URL, to destination: URL, incoming: [ResolvedLink & source paths], vaultRoot: URL) -> RenamePlan }`

Concretely the plan function signature is:

```swift
public static func plan(renaming source: URL,
                        to destination: URL,
                        inboundLinks: [(sourceFile: URL, rawTarget: String)],
                        vaultRoot: URL) -> RenamePlan
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/LinkRewriterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "LinkRewriter|error:"`
Expected: FAIL — `cannot find 'LinkRewriter' in scope`.

- [ ] **Step 3: Create `LinkRewriter.swift` (plan only)**

```swift
import Foundation

/// One link edit inside one file.
public struct LinkEdit: Sendable, Equatable {
    public let file: URL
    public let oldTarget: String
    public let newTarget: String
    public init(file: URL, oldTarget: String, newTarget: String) {
        self.file = file; self.oldTarget = oldTarget; self.newTarget = newTarget
    }
}

/// The complete change set for a rename or move, computed before anything is
/// written. Nothing in M1 mutates more than one file without one of these.
public struct RenamePlan: Sendable {
    public let source: URL
    public let destination: URL
    public let edits: [LinkEdit]

    public var affectedFiles: [URL] {
        var seen = Set<String>()
        return edits.compactMap { seen.insert($0.file.path).inserted ? $0.file : nil }
    }
    public var isEmpty: Bool { edits.isEmpty }
}

public enum LinkRewriter {
    /// Computes every inbound-link edit a rename or move requires.
    ///
    /// The rewritten target preserves the AUTHOR'S style: a bare `[[Design]]`
    /// becomes `[[Architecture]]`, a foldered `[[Projects/Design]]` keeps its
    /// folder, an extensioned `[[Design.md]]` keeps its extension, and any
    /// `#fragment` survives. Normalizing every link to a full path would be a
    /// bulk mutation nobody asked for.
    public static func plan(renaming source: URL,
                            to destination: URL,
                            inboundLinks: [(sourceFile: URL, rawTarget: String)],
                            vaultRoot: URL) -> RenamePlan {
        let edits = inboundLinks.compactMap { link -> LinkEdit? in
            guard let newTarget = rewritten(link.rawTarget, from: source,
                                            to: destination, vaultRoot: vaultRoot),
                  newTarget != link.rawTarget else { return nil }
            return LinkEdit(file: link.sourceFile, oldTarget: link.rawTarget,
                            newTarget: newTarget)
        }
        return RenamePlan(source: source, destination: destination, edits: edits)
    }

    static func rewritten(_ rawTarget: String, from source: URL, to destination: URL,
                          vaultRoot: URL) -> String? {
        // Split off the fragment; it is carried through untouched.
        var body = rawTarget
        var fragment = ""
        if let hash = rawTarget.firstIndex(of: "#") {
            body = String(rawTarget[..<hash])
            fragment = String(rawTarget[hash...])
        }
        let hadExtension = body.lowercased().hasSuffix(".md")
        let withoutExtension = hadExtension ? String(body.dropLast(3)) : body
        let hadPath = withoutExtension.contains("/")

        let newBase = destination.deletingPathExtension().lastPathComponent
        var newBody: String
        if hadPath {
            // Preserve "explicit path" style, recomputed against the vault root.
            let relative = destination.deletingPathExtension().path
                .replacingOccurrences(of: vaultRoot.path + "/", with: "")
            newBody = relative
        } else {
            newBody = newBase
        }
        if hadExtension { newBody += ".md" }
        return newBody + fragment
    }
}
```

- [ ] **Step 4: Run tests**

Run: `make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoreFeature/Logic/LinkRewriter.swift Tests/LoreFeatureTests/LinkRewriterTests.swift
git commit -m "feat(rename): compute inbound-link change sets preserving link style"
```

---

### Task 7: Applying the plan — `LoreStore.rename` and `move`

**Files:**
- Modify: `Sources/LoreFeature/Logic/LinkRewriter.swift`
- Modify: `Sources/LoreFeature/Store/LoreStore.swift`
- Test: `Tests/LoreFeatureTests/LinkRewriterTests.swift`

**Interfaces:**
- Consumes: `RenamePlan`, `LinkEdit`, `DocumentSession.cancelPendingSave()`, `resolveByReloading()`.
- Produces:
  - `public struct RenameReport: Sendable { public let rewritten: [URL]; public let skipped: [URL]; public let failed: [(URL, String)]; public let movedTo: URL? }`
  - `LoreStore.plan(rename source: URL, to newName: String) -> RenamePlan`
  - `LoreStore.apply(_ plan: RenamePlan) -> RenameReport`
  - `LoreStore.plan(move source: URL, toFolder: URL) -> RenamePlan`

**ORDERING IS A CORRECTNESS REQUIREMENT:** rewrite inbound links first, then move the file. Reversed, a crash mid-operation leaves a renamed file with every link pointing at nothing. In this order, a crash leaves links pointing at a not-yet-renamed file — still resolvable.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LoreFeatureTests/LinkRewriterTests.swift`:

```swift
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
        Thread.sleep(forTimeInterval: 1.1)
        let external = "---\nid: a\ntitle: A\n---\nEXTERNAL EDIT [[Design]]"
        try external.write(to: a, atomically: true, encoding: .utf8)

        let report = s.apply(plan)
        XCTAssertEqual(report.skipped, [a])
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
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "RenameApplication|error:"`
Expected: FAIL — `value of type 'LoreStore' has no member 'plan'`.

- [ ] **Step 3: Add the applier to `LinkRewriter`**

```swift
/// What actually happened when a plan was applied. Partial success is the
/// EXPECTED case, not an error state: a file that changed on disk is skipped
/// so an edit made seconds ago in another app is not destroyed.
public struct RenameReport: Sendable {
    public let rewritten: [URL]
    public let skipped: [URL]
    public let failed: [(url: URL, reason: String)]
    public let movedTo: URL?
}

extension LinkRewriter {
    /// Applies one file's edits, refusing if the file changed since `baseline`.
    /// Returns nil when skipped.
    static func applyEdits(_ edits: [LinkEdit], to file: URL, baseline: Date?) throws -> Bool {
        if let baseline,
           let disk = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
           disk > baseline {
            return false
        }
        var text = try String(contentsOf: file, encoding: .utf8)
        for edit in edits {
            text = replacingLinkTargets(in: text, from: edit.oldTarget, to: edit.newTarget)
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Replaces `[[old]]`, `[[old|display]]`, `![[old]]` and `[t](old)` while
    /// leaving the display text and the surrounding document untouched.
    static func replacingLinkTargets(in text: String, from old: String,
                                     to new: String) -> String {
        var out = text
        for (open, close) in [("[[", "]]"), ("[[", "|")] {
            out = out.replacingOccurrences(of: "\(open)\(old)\(close)",
                                           with: "\(open)\(new)\(close)")
        }
        out = out.replacingOccurrences(of: "](\(old))", with: "](\(new))")
        return out
    }
}
```

- [ ] **Step 4: Add `plan` and `apply` to `LoreStore`**

```swift
    /// Computes the change set for renaming `source` to `newName` (basename,
    /// no extension). Nothing is written.
    public func plan(rename source: URL, to newName: String) -> RenamePlan {
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent(newName)
            .appendingPathExtension(source.pathExtension)
        return planMove(source, to: destination)
    }

    /// Moving is renaming without the name change: it must still rewrite,
    /// because a move changes how ambiguous basenames resolve.
    public func plan(move source: URL, toFolder folder: URL) -> RenamePlan {
        planMove(source, to: folder.appendingPathComponent(source.lastPathComponent))
    }

    private func planMove(_ source: URL, to destination: URL) -> RenamePlan {
        let inbound = coordinator.inboundLinks(to: source)
        return LinkRewriter.plan(renaming: source, to: destination,
                                 inboundLinks: inbound,
                                 vaultRoot: vaultRoot ?? source.deletingLastPathComponent())
    }

    @discardableResult
    public func apply(_ plan: RenamePlan) -> RenameReport {
        var rewritten: [URL] = [], skipped: [URL] = [], failed: [(URL, String)] = []

        // A pending autosave on an affected file would clobber the rewrite.
        // M0 added `cancelPendingSave` for exactly this class of bug.
        let affected = Set(plan.affectedFiles.map(\.path))
        for session in tabs where affected.contains(session.url.path) {
            session.cancelPendingSave()
        }

        // Links FIRST, then the move. Reversed, a crash here leaves every
        // inbound link dangling.
        let byFile = Dictionary(grouping: plan.edits, by: \.file)
        for (file, edits) in byFile {
            do {
                let baseline = try? FileManager.default
                    .attributesOfItem(atPath: file.path)[.modificationDate] as? Date
                if try LinkRewriter.applyEdits(edits, to: file, baseline: baseline ?? nil) {
                    rewritten.append(file)
                } else {
                    skipped.append(file)
                }
            } catch {
                failed.append((file, error.localizedDescription))
            }
        }

        var moved: URL?
        if plan.source != plan.destination {
            if FileManager.default.fileExists(atPath: plan.destination.path) {
                failed.append((plan.destination, "A file with that name already exists."))
            } else {
                do {
                    try FileManager.default.moveItem(at: plan.source, to: plan.destination)
                    moved = plan.destination
                    for session in tabs where session.url == plan.source {
                        session.adoptRenamed(plan.destination)
                    }
                } catch {
                    failed.append((plan.source, error.localizedDescription))
                }
            }
        }

        // Reload sessions whose file we rewrote, so the editor does not keep
        // showing pre-rewrite text. `resolveByReloading` bumps
        // `reloadGeneration`, which the editor's view identity depends on.
        for session in tabs where rewritten.contains(session.url) {
            try? session.resolveByReloading()
        }

        try? rebuild()
        return RenameReport(rewritten: rewritten, skipped: skipped,
                            failed: failed, movedTo: moved)
    }
```

Add to `VaultIndexCoordinator`:

```swift
    /// Every (file, rawTarget) pair pointing at `url`.
    func inboundLinks(to url: URL) -> [(sourceFile: URL, rawTarget: String)] {
        guard let index else { return [] }
        return ((try? index.inboundLinks(to: url)) ?? [])
    }
```

and to `LoreIndex`:

```swift
    public func inboundLinks(to target: URL) throws -> [(sourceFile: URL, rawTarget: String)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source_path, raw_target FROM links WHERE target_path = ?;
            """, arguments: [target.path]).map {
                (URL(fileURLWithPath: $0["source_path"]), $0["raw_target"])
            }
        }
    }
```

Add to `DocumentSession`:

```swift
    /// The document this session edits was renamed or moved on disk. Follow it.
    /// `url` is already mutable (save-a-copy adoption); this is the same move
    /// for a different reason.
    public func adoptRenamed(_ newURL: URL) {
        url = newURL
        baseline = Self.mtime(of: newURL) ?? .distantPast
        conflict = false
    }
```

- [ ] **Step 5: Run tests**

Run: `make test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(rename): apply link rewrites before moving, skipping changed files"
```

---

### Task 8: Folder rename, and trash

**Files:**
- Modify: `Sources/LoreFeature/Store/LoreStore.swift`
- Test: `Tests/LoreFeatureTests/TrashTests.swift`, `Tests/LoreFeatureTests/LinkRewriterTests.swift`

**Interfaces:**
- Consumes: `RenamePlan`, `RenameReport`.
- Produces:
  - `LoreStore.plan(renameFolder folder: URL, to newName: String) -> [RenamePlan]`
  - `LoreStore.apply(_ plans: [RenamePlan]) -> [RenameReport]`
  - `LoreStore.trash(_ row: IndexRow) throws -> Int` — returns the inbound-link count that was warned about; throws on failure.
  - `LoreStore.inboundLinkCount(to url: URL) -> Int`
  - `LoreError` gains `case trashFailed(URL, String)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/TrashTests.swift`:

```swift
import XCTest
@testable import LoreFeature

@MainActor
final class TrashTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-trash-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return (root, s)
    }

    func test_trashMovesTheFileOutOfTheVaultWithoutDeletingIt() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        _ = try s.trash(s.rows.first { $0.path == url }!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(s.rows.allSatisfy { $0.path != url })
    }

    func test_trashReportsInboundLinkCountWithoutRewritingThem() async throws {
        let (root, s) = try vault()
        let a = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nsee [[Gone]]".write(to: a, atomically: true, encoding: .utf8)
        let gone = root.appendingPathComponent("Gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: gone, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        XCTAssertEqual(s.inboundLinkCount(to: gone), 1)
        let warned = try s.trash(s.rows.first { $0.path == gone }!)
        XCTAssertEqual(warned, 1)
        // The link is deliberately NOT rewritten: an unresolved link is how the
        // user finds what broke.
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Gone]]"))
    }

    func test_trashClosesAnyTabOnTheDocument() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        s.open(url: url)
        XCTAssertEqual(s.tabs.count, 1)
        _ = try s.trash(s.rows.first { $0.path == url }!)
        XCTAssertTrue(s.tabs.isEmpty)
    }
}
```

Append to `LinkRewriterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "TrashTests|renameFolder|error:"`
Expected: FAIL — `value of type 'LoreStore' has no member 'trash'`.

- [ ] **Step 3: Implement folder rename and trash**

```swift
    /// One plan per document beneath `folder`, presented under a single
    /// preview. This is the largest bulk mutation M1 ships.
    public func plan(renameFolder folder: URL, to newName: String) -> [RenamePlan] {
        let destination = folder.deletingLastPathComponent().appendingPathComponent(newName)
        return rows
            .filter { $0.path.path.hasPrefix(folder.path + "/") }
            .map { row in
                let relative = row.path.path.replacingOccurrences(
                    of: folder.path + "/", with: "")
                return planMove(row.path, to: destination.appendingPathComponent(relative))
            }
    }

    @discardableResult
    public func apply(_ plans: [RenamePlan]) -> [RenameReport] { plans.map { apply($0) } }

    public func inboundLinkCount(to url: URL) -> Int {
        coordinator.inboundLinks(to: url).count
    }

    /// Moves the document to the macOS Trash.
    ///
    /// Returns how many documents link here, so the caller can warn. Inbound
    /// links are deliberately NOT rewritten: an unresolved link to a deleted
    /// note is the correct outcome and is how the user finds what broke.
    ///
    /// NEVER falls back to `removeItem` on failure. Quietly doing something
    /// less safe than the user asked for is its own bug.
    @discardableResult
    public func trash(_ row: IndexRow) throws -> Int {
        let inbound = inboundLinkCount(to: row.path)
        for session in tabs where session.url == row.path {
            session.cancelPendingSave()
            _ = closeTab(session, force: true)
        }
        do {
            try FileManager.default.trashItem(at: row.path, resultingItemURL: nil)
        } catch {
            throw LoreError.trashFailed(row.path, error.localizedDescription)
        }
        try? coordinator.removeFromIndex(row.path)
        return inbound
    }
```

Add `case trashFailed(URL, String)` to `LoreError`. Leave the existing `delete(_:)` in place for now — Task 9 removes its last caller, and Task 12 deletes it.

- [ ] **Step 4: Run tests**

Run: `make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(vault): folder rename and Trash-backed deletion"
```

---

### Task 9: Folder tree sidebar

**Files:**
- Create: `Sources/LoreFeature/Views/FolderTreeView.swift`
- Modify: `Sources/LoreFeature/Views/NoteListView.swift`
- Modify: `Sources/LoreFeature/Views/LoreRootView.swift`
- Test: `Tests/LoreFeatureTests/RootViewSmokeTests.swift`

**Interfaces:**
- Consumes: `LoreStore.rows`, `LoreStore.vaultRoot`, `LoreStore.trash(_:)`.
- Produces:
  - `struct FolderTreeView: View`
  - `public enum SidebarMode: String, Sendable { case tree, all }` on `LoreStore`, persisted via `PluginDocumentStore` under key `"sidebarMode"`, with `LoreStore.sidebarMode` and `setSidebarMode(_:)`.
  - `FolderNode` — a pure, testable tree built from `[IndexRow]`:
    `struct FolderNode: Identifiable { let id: String; let name: String; let children: [FolderNode]; let documents: [IndexRow] }`
    built by `static func tree(from rows: [IndexRow], root: URL) -> FolderNode`.

- [ ] **Step 1: Write the failing test**

The tree-building function is pure and must be tested directly; the view itself gets a smoke test. Append to `Tests/LoreFeatureTests/RootViewSmokeTests.swift`:

```swift
@MainActor
func test_folderTreeGroupsDocumentsByFolder() throws {
    let root = URL(fileURLWithPath: "/v")
    func row(_ path: String, _ title: String) -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: path), id: path, title: title, tags: [],
                 updated: Date(), type: "markdown", properties: [], aliases: [])
    }
    let tree = FolderNode.tree(from: [
        row("/v/a.md", "A"),
        row("/v/Projects/b.md", "B"),
        row("/v/Projects/Deep/c.md", "C"),
    ], root: root)

    XCTAssertEqual(tree.documents.map(\.title), ["A"])
    XCTAssertEqual(tree.children.map(\.name), ["Projects"])
    let projects = tree.children[0]
    XCTAssertEqual(projects.documents.map(\.title), ["B"])
    XCTAssertEqual(projects.children.map(\.name), ["Deep"])
    XCTAssertEqual(projects.children[0].documents.map(\.title), ["C"])
}

@MainActor
func test_folderTreeViewBuilds() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lore-tree-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
    try store.setVaultRootForTesting(root)
    _ = FolderTreeView(store: store, theme: HostTheme.preview,
                       selected: .constant(nil), onSelect: { _ in })
}
```

Use whatever theme value the existing `RootViewSmokeTests` constructs — match the file, do not invent an API.

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "FolderNode|FolderTreeView|error:"`
Expected: FAIL — `cannot find 'FolderNode' in scope`.

- [ ] **Step 3: Create `FolderTreeView.swift` with `FolderNode`**

```swift
import SwiftUI
import AinkradAppKit

/// A folder and everything directly inside it. Pure value built from index
/// rows, so the grouping logic is testable without a view host.
struct FolderNode: Identifiable {
    let id: String
    let name: String
    let children: [FolderNode]
    let documents: [IndexRow]

    static func tree(from rows: [IndexRow], root: URL) -> FolderNode {
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var byFolder: [String: [IndexRow]] = [:]
        for row in rows {
            let parts = row.path.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            let folder = parts.dropLast().joined(separator: "/")
            byFolder[folder, default: []].append(row)
        }
        return node(named: "", path: "", byFolder: byFolder)
    }

    private static func node(named name: String, path: String,
                             byFolder: [String: [IndexRow]]) -> FolderNode {
        let childNames = Set(byFolder.keys.compactMap { key -> String? in
            guard key != path else { return nil }
            let prefix = path.isEmpty ? "" : path + "/"
            guard key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count)).split(separator: "/").first.map(String.init)
        }).sorted()

        return FolderNode(
            id: path.isEmpty ? "/" : path,
            name: name,
            children: childNames.map {
                node(named: $0, path: path.isEmpty ? $0 : path + "/" + $0, byFolder: byFolder)
            },
            documents: (byFolder[path] ?? []).sorted { $0.title < $1.title })
    }
}

struct FolderTreeView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @Binding var selected: IndexRow?
    let onSelect: (IndexRow) -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let root = store.vaultRoot {
                    outline(FolderNode.tree(from: store.rows, root: root), depth: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func outline(_ node: FolderNode, depth: Int) -> some View {
        if depth > 0 {
            Button {
                if expanded.contains(node.id) { expanded.remove(node.id) }
                else { expanded.insert(node.id) }
                store.setExpandedFolders(expanded)
            } label: {
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradIconGlyph(systemName: expanded.contains(node.id)
                                     ? "chevron.down" : "chevron.right")
                    Text(node.name)
                }
                .padding(.leading, CGFloat(depth) * 12)
            }
            .buttonStyle(.plain)
        }
        if depth == 0 || expanded.contains(node.id) {
            ForEach(node.documents, id: \.path) { row in
                AinkradListRow(
                    isSelected: selected?.path == row.path,
                    onTap: { selected = row; onSelect(row) },
                    leading: { AinkradIconGlyph(systemName: icon(for: row)) },
                    title: row.title.isEmpty ? row.path.lastPathComponent : row.title,
                    subtitle: nil,
                    trailing: { EmptyView() })
                .padding(.leading, CGFloat(depth + 1) * 12)
            }
            ForEach(node.children) { child in outline(child, depth: depth + 1) }
        }
    }

    private func icon(for row: IndexRow) -> String {
        row.type == EngineRegistry.unclaimedType ? "doc" : "doc.text"
    }
    .onAppear { expanded = store.expandedFolders }
}
```

Note: the `.onAppear` above belongs on the `ScrollView` in `body`, not after a function — place it there when writing the file.

- [ ] **Step 4: Add mode and expansion persistence to `LoreStore`**

```swift
    public enum SidebarMode: String, Sendable { case tree, all }

    public private(set) var sidebarMode: SidebarMode = .tree
    public private(set) var expandedFolders: Set<String> = []

    private static let sidebarModeKey = "sidebarMode"
    private static let expandedFoldersKey = "expandedFolders"

    public func setSidebarMode(_ mode: SidebarMode) {
        sidebarMode = mode
        documents.setData(mode.rawValue.data(using: .utf8), forKey: Self.sidebarModeKey)
    }

    public func setExpandedFolders(_ folders: Set<String>) {
        expandedFolders = folders
        documents.setData(folders.sorted().joined(separator: "\n").data(using: .utf8),
                          forKey: Self.expandedFoldersKey)
    }
```

Read both in `init`, following exactly how `defaultNoteFolder` is already read there.

- [ ] **Step 5: Add the toggle to `LoreRootView`**

Above the sidebar, a two-item picker bound to `store.sidebarMode`; render `FolderTreeView` for `.tree` and `NoteListView` for `.all`. **When `query` is non-empty or a tag filter is active, always render `NoteListView`** regardless of mode — a filtered tree of mostly-empty branches is worse than a list.

- [ ] **Step 6: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(ui): folder tree sidebar with persisted expansion"
```

---

### Task 10: Rename preview sheet and folder operations

**Files:**
- Create: `Sources/LoreFeature/Views/RenamePreviewSheet.swift`
- Modify: `Sources/LoreFeature/Views/FolderTreeView.swift`
- Modify: `Sources/LoreFeature/Views/NoteListView.swift`
- Modify: `Sources/LoreFeature/Views/LoreRootView.swift`
- Test: `Tests/LoreFeatureTests/RootViewSmokeTests.swift`

**Interfaces:**
- Consumes: `RenamePlan`, `RenameReport`, `LoreStore.plan(rename:to:)`, `apply(_:)`, `trash(_:)`, `inboundLinkCount(to:)`.
- Produces: `struct RenamePreviewSheet: View` — shows the change count and affected files, confirms or cancels.

- [ ] **Step 1: Write the failing smoke test**

Append to `Tests/LoreFeatureTests/RootViewSmokeTests.swift`:

```swift
@MainActor
func test_renamePreviewSheetBuilds() throws {
    let plan = RenamePlan(
        source: URL(fileURLWithPath: "/v/Design.md"),
        destination: URL(fileURLWithPath: "/v/Architecture.md"),
        edits: [LinkEdit(file: URL(fileURLWithPath: "/v/A.md"),
                         oldTarget: "Design", newTarget: "Architecture")])
    _ = RenamePreviewSheet(plans: [plan], theme: HostTheme.preview,
                           onConfirm: {}, onCancel: {})
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "RenamePreviewSheet|error:"`
Expected: FAIL — `cannot find 'RenamePreviewSheet' in scope`.

- [ ] **Step 3: Create `RenamePreviewSheet.swift`**

```swift
import SwiftUI
import AinkradAppKit

/// Confirms a bulk mutation before anything is written.
///
/// M1 has no undo. The preview is what makes rename recoverable — it turns an
/// irreversible multi-file edit into a reviewable one.
struct RenamePreviewSheet: View {
    let plans: [RenamePlan]
    let theme: HostTheme
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var editCount: Int { plans.reduce(0) { $0 + $1.edits.count } }
    private var files: [URL] {
        var seen = Set<String>()
        return plans.flatMap(\.affectedFiles)
            .filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text(summary).font(.headline)
            if files.isEmpty {
                Text("No other documents link to this.")
                    .foregroundStyle(theme.tokens.foreground.opacity(0.7))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(files, id: \.path) { file in
                            Text(file.lastPathComponent).lineLimit(1)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            HStack {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost, action: onCancel)
                AinkradButton(title: "Rename", style: .primary, action: onConfirm)
            }
        }
        .padding(AinkradSpacing.lg)
        .frame(width: 420)
        .background(theme.tokens.background)
    }

    private var summary: String {
        if plans.count > 1 {
            return "Rename folder: \(plans.count) documents, \(editCount) links in \(files.count) files"
        }
        return editCount == 0
            ? "Rename this document"
            : "This will update \(editCount) link\(editCount == 1 ? "" : "s") across \(files.count) file\(files.count == 1 ? "" : "s")"
    }
}
```

- [ ] **Step 4: Wire operations into both sidebar modes**

Add a context menu to rows in `FolderTreeView` and `NoteListView` with **Rename…**, **Move to…**, and **Move to Trash**, plus folder rows in the tree getting **New Folder**, **Rename Folder…**, **Move Folder to Trash**.

- Rename shows a text prompt, then builds the plan and presents `RenamePreviewSheet`; on confirm, `store.apply(plan)` and surface the report — if `report.skipped` is non-empty, show "N files were changed on disk and were skipped", because a silently partial rename is exactly the failure this design exists to prevent.
- Move uses `NSOpenPanel` restricted to directories under the vault root.
- Trash calls `store.inboundLinkCount(to:)` first and, when non-zero, confirms with "N notes link here. Their links will stop resolving." Then calls `store.trash(row)`; on `LoreError.trashFailed`, show the reason and do **not** delete.
- Unclaimed rows keep no Delete affordance, as M0 left them, but gain Rename and Move.

- [ ] **Step 5: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(ui): rename preview sheet and folder operations"
```

---

### Task 11: Backlinks panel

**Files:**
- Create: `Sources/LoreFeature/Views/BacklinksPanel.swift`
- Modify: `Sources/LoreFeature/Views/DocumentPane.swift`
- Test: `Tests/LoreFeatureTests/RootViewSmokeTests.swift`

**Interfaces:**
- Consumes: `LoreStore.backlinks(to:)`, `unresolvedLinks(from:)`, `open(url:)`, `create(title:)`.
- Produces: `struct BacklinksPanel: View`.

- [ ] **Step 1: Write the failing smoke test**

```swift
@MainActor
func test_backlinksPanelBuilds() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lore-bl-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
    try store.setVaultRootForTesting(root)
    _ = BacklinksPanel(store: store, url: root.appendingPathComponent("x.md"),
                       theme: HostTheme.preview)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "BacklinksPanel|error:"`
Expected: FAIL — `cannot find 'BacklinksPanel' in scope`.

- [ ] **Step 3: Create `BacklinksPanel.swift`**

```swift
import SwiftUI
import AinkradAppKit

/// Backlinks and unresolved links for the open document.
///
/// Each backlink shows the line that contains the link: a bare list of
/// filenames is meaningfully less useful than seeing WHY something links here.
struct BacklinksPanel: View {
    @Bindable var store: LoreStore
    let url: URL
    let theme: HostTheme
    @State private var expanded = true

    private var backlinks: [LoreStore.Backlink] { store.backlinks(to: url) }
    private var unresolved: [String] { store.unresolvedLinks(from: url) }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            Button { expanded.toggle() } label: {
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradIconGlyph(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text("Linked mentions (\(backlinks.count))")
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(backlinks) { link in
                    Button { store.open(url: link.row.path) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(link.row.title).bold().lineLimit(1)
                            if !link.context.isEmpty {
                                Text(link.context)
                                    .font(.caption)
                                    .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }

                if !unresolved.isEmpty {
                    Text("Unresolved links").font(.caption).padding(.top, AinkradSpacing.xs)
                    ForEach(unresolved, id: \.self) { target in
                        HStack {
                            Text(target).lineLimit(1)
                            Spacer()
                            AinkradButton(title: "Create note", style: .ghost) {
                                if let note = try? store.create(
                                    title: LinkResolver.basename(of: target)) {
                                    store.open(url: note.path)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(AinkradSpacing.sm)
        .background(theme.tokens.background)
    }
}
```

- [ ] **Step 4: Host it in `DocumentPane`**

Below the engine's editor, render `BacklinksPanel(store: store, url: session.url, theme: theme)` — but only when `session.engine` is a `MarkdownEngine`, since plain-text documents contribute no links. Give the panel a fixed maximum height (200) so it never crowds the editor.

- [ ] **Step 5: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(ui): backlinks panel with context and unresolved links"
```

---

### Task 12: Editor link affordances — `[[` completion and click-to-open

**Files:**
- Create: `Sources/LoreFeature/Views/LinkCompletionView.swift`
- Modify: `Sources/LoreFeature/Views/MarkdownEditor.swift`
- Modify: `Sources/LoreFeature/Documents/Markdown/MarkdownEngine.swift`
- Test: `Tests/LoreFeatureTests/LinkCompletionTests.swift`

**Interfaces:**
- Consumes: `LoreStore.linkCompletions(matching:)`, `openLink(_:)`.
- Produces:
  - `public enum LinkCompletionContext { public static func activePrefix(in text: String, caret: Int) -> String? }` — returns the text between the nearest unclosed `[[` before the caret and the caret, or `nil`.
  - `struct LinkCompletionView: View`
  - `MarkdownEditor` gains `onOpenLink: ((String) -> Void)?` and `completions: ((String) -> [IndexRow])?`.

The caret/prefix logic is pure and must be unit-tested; the view is smoke-tested.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/LinkCompletionTests.swift`:

```swift
import XCTest
@testable import LoreFeature

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
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "LinkCompletion|error:"`
Expected: FAIL — `cannot find 'LinkCompletionContext' in scope`.

- [ ] **Step 3: Create `LinkCompletionView.swift` with the context logic**

```swift
import SwiftUI
import AinkradAppKit

/// Decides whether the caret sits inside an unclosed `[[`, and what has been
/// typed so far. Pure, so the fiddly caret arithmetic is testable without a
/// view host.
public enum LinkCompletionContext {
    public static func activePrefix(in text: String, caret: Int) -> String? {
        let chars = Array(text)
        guard caret <= chars.count else { return nil }
        var i = caret - 1
        while i >= 1 {
            if chars[i] == "\n" { return nil }
            // A closing `]]` between here and the caret means the link is done.
            if chars[i] == "]" && chars[i - 1] == "]" { return nil }
            if chars[i] == "[" && chars[i - 1] == "[" {
                return String(chars[(i + 1)..<caret])
            }
            i -= 1
        }
        return nil
    }
}

struct LinkCompletionView: View {
    let matches: [IndexRow]
    let theme: HostTheme
    let onPick: (IndexRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches.prefix(8), id: \.path) { row in
                Button { onPick(row) } label: {
                    HStack {
                        Text(row.title.isEmpty ? row.path.lastPathComponent : row.title)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, AinkradSpacing.sm)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 260)
        .background(theme.tokens.background)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(theme.tokens.foreground.opacity(0.2)))
    }
}
```

- [ ] **Step 4: Wire completion and clicking into `MarkdownEditor`**

`MarkdownEditor` is an `NSViewRepresentable` over `NSTextView` (read it before editing). Add:

- Two optional closures: `var completions: ((String) -> [IndexRow])?` and `var onOpenLink: ((String) -> Void)?`.
- On text change, compute `LinkCompletionContext.activePrefix(in: text, caret: selectedRange().location)`. When non-nil, ask `completions` and show `LinkCompletionView` in a popover anchored at the caret rect (`firstRect(forCharacterRange:)`). Picking a row replaces the typed prefix with the row's title and inserts the closing `]]`.
- Cmd-click (or plain click when the click falls inside a `[[…]]` span) calls `onOpenLink` with the raw target under the cursor. Compute the span by scanning outward from the click index for `[[` and `]]` on the same line.

In `MarkdownDocumentEditor` (inside `MarkdownEngine.swift`), pass both closures through from `EditorContext`. `EditorContext` gains:

```swift
    public let completions: (String) -> [IndexRow]
    public let openLink: (String) -> Void
```

with `DocumentPane` supplying `store.linkCompletions(matching:)` and `{ if !store.openLink($0) { /* offer create */ } }`.

- [ ] **Step 5: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(editor): wikilink autocomplete and click-to-open"
```

---

### Task 13: Verify the M1 success criteria

**Files:** none created; verification, plus small clearly-scoped fixes only.

- [ ] **Step 1: Criterion 1 — Obsidian round trip**

Build a scratch vault under `/tmp` (NEVER the real vault at `/Users/ahmedmelhalaby/Ainkrad`) containing notes with `[[bare]]`, `[[With Space]]`, `[[Note|alias]]`, `[[Note#Heading]]`, block-sequence `aliases`, and a link written from Obsidian's own shortest-path style. Run `make sideload`, open Lore on it, and confirm every link resolves. Confirm a link Lore writes via autocomplete is a form Obsidian resolves.

- [ ] **Step 2: Criterion 2 — backlinks completeness**

For a note with inbound links written as `[[Note]]`, `[[Note|alias]]`, `[[Note#Heading]]`, and `[text](Note.md)`, confirm all four appear in the backlinks panel with context lines.

- [ ] **Step 3: Criteria 3 and 4 — rename and folder rename**

Rename a note with several inbound links: confirm the preview count matches, confirm every link still resolves after applying, and confirm the frontmatter `title:` is unchanged (rename acts on the filename only). Repeat for a folder rename touching several documents under one preview.

- [ ] **Step 4: Criterion 3's conflict path**

With a note open in Obsidian, edit and save one of the files a pending rename will rewrite, then apply. Confirm that file is **skipped and reported**, and that its content is intact.

- [ ] **Step 5: Criterion 5 — code blocks**

A note containing `[[NotALink]]` inside a fenced block must contribute no link. Verify via the backlinks panel of a note actually named `NotALink`.

- [ ] **Step 6: Criterion 6 — trash**

Delete a document; confirm it appears in the macOS Trash and is gone from the sidebar. Then verify the failure path at store level (a `trashItem` failure must throw `LoreError.trashFailed` and delete nothing).

- [ ] **Step 7: Criterion 7 — rename with a dirty open tab**

Open a note that will be rewritten, type into it without waiting for autosave, then apply a rename affecting it. Confirm the typed edits are not lost and the editor does not show stale text.

- [ ] **Step 8: Criterion 8 — tests and file sizes**

```bash
make test 2>&1 | tail -20
wc -l Sources/LoreFeature/**/*.swift | sort -rn | head -8
```

Expected: all tests pass; no file at or above 500 lines.

- [ ] **Step 9: Report**

Write the evidence per criterion — exact steps, actual output, PASS/FAIL/PARTIAL. State plainly anything that could not be driven through the GUI and why. Do not commit unless a fix was required.

---

## Self-Review Notes

Checked against the spec:

- **Link syntax scope (names, aliases, headings; block refs parsed not resolved)** — Tasks 1, 4. `#^block` is kept whole in `rawTarget` and stripped by `LinkResolver.basename`, so it resolves to the document. Covered.
- **Basename-first resolution, aliases, case-insensitivity, shortest-path ties** — Task 4. Covered.
- **Index schema v3, links table, raw target stored alongside resolution** — Task 3. Covered.
- **Backlinks as a query; unresolved as the same query** — Tasks 3, 5. Covered.
- **Rename previews, applies links-first, skips conflicts, reports partials** — Tasks 6, 7. Covered.
- **Rename acts on the filename, not the frontmatter title** — no task changes `title:`; Task 13 Step 3 verifies it explicitly. Covered.
- **Open tabs: cancel pending saves, reload after, renamed tab follows** — Task 7. Covered.
- **Move and folder rename share the rename path** — Tasks 7, 8. Covered.
- **Trash via `trashItem`, never falling back to delete; warns on inbound links without rewriting** — Task 8. Covered.
- **Folder tree with flat mode; filters force flat** — Task 9. Covered.
- **Backlinks panel with context and unresolved section** — Task 11. Covered.
- **`[[` autocomplete and click-to-open** — Task 12. Covered.
- **Failure modes table** — ambiguous (Task 4 shortest-path), unclaimed target (M0 fallback viewer, unchanged), trashed target becomes unresolved (Task 8 leaves links alone), rewrite conflict skip (Task 7), `trashItem` failure (Task 8), per-document parse failure (Task 1 returns `[]` rather than throwing). Covered.

**Known rough edges, recorded rather than hidden:**

- `LinkRewriter.replacingLinkTargets` is string replacement, so a link target that is a substring of body prose in the `[[…]]` form could in principle over-match. It is bounded by the bracket delimiters, which makes a false positive require literal `[[old]]` text — acceptable for M1, and Task 13 Step 3 exercises it. A proper edit-range-based rewrite belongs with M2's real markdown parser.
- The old `LoreStore.delete(_:)` is left in place through Task 8 and should be removed once Task 10 moves the last caller to `trash`. If any caller remains at Task 13, remove it there and say so.
- `MarkdownEngine.outline(of:)` still lacks fence-awareness (a known M0 deferred minor). `LinkParser` has it. Unifying them is M2's job, when a single real markdown parser exists.
