# Lore M2a — Markdown Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace three disagreeing markdown scanners with one `swift-markdown` AST, then build in-place styling, outline navigation, and interactive task checkboxes on top of it.

**Architecture:** `MarkdownDocumentModel` parses a document's body once and derives style spans, outline entries, task items, and the text regions wikilink extraction may see. `SourceOffsetMap` converts the AST's line/column positions into UTF-16 offsets the editor can use. `MarkdownStyler` and `MarkdownEngine.outline` are deleted; M1's wikilink grammar survives untouched and its test suite is the regression gate.

**Tech Stack:** Swift 6.0, SwiftUI + AppKit (`NSTextView`), macOS 14.0+, `swift-markdown` (SPM product `Markdown`), GRDB 6.29.3, AinkradAppKit, XCTest + swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-30-lore-m2a-markdown-core-design.md`

## Global Constraints

- Swift 6.0, strict concurrency. `MACOSX_DEPLOYMENT_TARGET` 14.0.
- **No source file may exceed 500 lines.** Current largest: `Frontmatter.swift` 490, `LinkRewriter.swift` 467. Do not grow either.
- Build/test only via `make generate && make test`. Never `swift build` / `swift test` — this is an Xcode bundle target. `make test` takes several minutes; use a 600000ms timeout.
- `AinkradLore.xcodeproj` is gitignored: run `make generate` after adding files or packages, never commit the project file.
- All existing tests stay green at every task boundary: **341 XCTest + 46 swift-testing, 0 failures** at the start of M2a.
- **Degrade, never block.** A parse failure leaves previous styling in place; a source location that fails to map is dropped, never applied to a wrong range.
- **Task toggling goes through the normal edit path** — same undo stack, dirty flag, autosave debounce and external-change guard. Never a direct write.
- Local commits on the feature branch are approved. **Never push, open a PR, or merge.**

## Inherited context an implementer cannot discover from their own task

- **Two different offset units already exist.** `LinkSpan.targetRange` is **Character** offsets into the scanned string. `StyleSpan.range` is **UTF-16** offsets into the editor's string. They are not interchangeable. M1 lost review rounds to exactly this class of confusion; every new offset must state its unit in its declaration.
- **CRLF has bitten this codebase twice.** Swift treats `"\r\n"` as one `Character` but two UTF-16 code units. M1 found that `split(separator: "\n")` never splits a CRLF document, so a Windows-authored file scanned as a single line and no fences were detected at all.
- **Frontmatter is not part of the body.** `Frontmatter.bodyOffset` (in `Sources/LoreFeature/Logic/Frontmatter+Body.swift`) gives the Character offset where the body starts. The editor holds the whole file; the parser sees the body.
- `MarkdownEditor.applyStyles()` currently sets a base attribute set over the whole string, then adds attributes per `MarkdownStyler` span. It runs on **every keystroke**.
- `DocumentSession` owns `markChanged()`, `saveNow()`, `cancelPendingSave()`, `isDirty`, `conflict`, `isReadOnly`. `MarkdownEngine.note.body` is the text; the editor writes through the engine.
- `MarkdownEditor` already owns `[[` autocomplete, Cmd-click-to-open, a non-key `NSPanel`, and a scroll observer. None of that is in scope to change.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `Sources/LoreFeature/Logic/SourceOffsetMap.swift` | line/column → UTF-16 offset, CRLF- and Unicode-correct |
| `Sources/LoreFeature/Logic/MarkdownDocumentModel.swift` | Owns the parsed `Document`; derives spans, outline, tasks, text regions |
| `Sources/LoreFeature/Logic/MarkdownSpanBuilder.swift` | AST walk → `[StyleSpan]` |
| `Sources/LoreFeature/Logic/MarkdownTaskItems.swift` | AST walk → `[TaskItem]`, and the toggle edit |
| `Sources/LoreFeature/Views/OutlineSection.swift` | Outline list for the open document |
| `Tests/LoreFeatureTests/SourceOffsetMapTests.swift` | The adversarial offset set |
| `Tests/LoreFeatureTests/MarkdownSpanTests.swift` | Golden styling + code-fence inertness |
| `Tests/LoreFeatureTests/MarkdownTaskTests.swift` | Toggle through the edit path |
| `Tests/LoreFeatureTests/MarkdownStylingBenchmark.swift` | Parse-count bound under typing |

**Modified:**

| Path | Change |
|---|---|
| `project.yml` | Add the `swift-markdown` package and target dependency |
| `Sources/LoreFeature/Logic/LinkParser.swift` | Region detection delegated to the AST; grammar unchanged |
| `Sources/LoreFeature/Documents/Markdown/MarkdownEngine.swift` | `outline(of:)` deleted; outline + tasks from the model |
| `Sources/LoreFeature/Views/MarkdownEditor.swift` | Debounced parse, clear-before-apply, new span kinds, checkbox clicks |
| `Sources/LoreFeature/Views/DocumentPane.swift` | Hosts `OutlineSection` |

**Deleted:**

| Path | Reason |
|---|---|
| `Sources/LoreFeature/Logic/MarkdownStyler.swift` | Superseded by the AST walk |

---

### Task 1: Add `swift-markdown` and prove it parses

The dependency lands and one trivially-true fact is asserted through it. Nothing else. This task exists on its own because adding an SPM package to an Xcode **bundle** target has historically needed build-settings work in this project (GRDB required a custom module-map flag), and that risk should not be entangled with parser logic.

**Files:**
- Modify: `project.yml`
- Create: `Tests/LoreFeatureTests/MarkdownDependencyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: the `Markdown` module is importable from `LoreFeature` and its tests.

- [ ] **Step 1: Add the package**

In `project.yml`, under `packages:`, alongside `AinkradAppKit` and `GRDB`:

```yaml
  SwiftMarkdown:
    url: https://github.com/swiftlang/swift-markdown
    branch: main
```

`swift-markdown` does not publish semantic-version tags for all Swift releases; pin to `branch: main` initially and record the resolved revision in your report so a later task can pin it exactly.

Add to the `LoreFeature`, `LorePlugin`, and `LoreFeatureTests` targets' `dependencies:`, matching how `GRDB` is declared on each:

```yaml
      - package: SwiftMarkdown
        product: Markdown
```

- [ ] **Step 2: Write the failing test**

Create `Tests/LoreFeatureTests/MarkdownDependencyTests.swift`:

```swift
import XCTest
import Markdown
@testable import LoreFeature

final class MarkdownDependencyTests: XCTestCase {
    func test_parsesAHeadingAndAParagraph() {
        let doc = Document(parsing: "# Title\n\nbody text\n")
        XCTAssertEqual(doc.childCount, 2)
        XCTAssertTrue(doc.child(at: 0) is Heading)
        XCTAssertEqual((doc.child(at: 0) as? Heading)?.level, 1)
    }

    func test_reportsSourceRanges() {
        let doc = Document(parsing: "# Title\n")
        let heading = doc.child(at: 0) as? Heading
        XCTAssertNotNil(heading?.range, "source ranges must be populated; later tasks depend on them")
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `make generate && make test 2>&1 | grep -E "Markdown|error:"`
Expected: FAIL — `no such module 'Markdown'` before the package resolves, or a build error from the bundle target.

- [ ] **Step 4: Get the build green**

Resolve whatever the bundle target needs. If `Markdown` requires a module-map flag the way GRDB does, follow the existing `OTHER_SWIFT_FLAGS` pattern in the `LoreFeature` target and say so in your report. If `Document.range` turns out to need a non-default parse option, adjust the test to construct the document the way the library actually populates ranges, and **report the exact call you settled on** — every later task depends on it.

- [ ] **Step 5: Run tests**

Run: `make test 2>&1 | tail -30`
Expected: PASS, plus all 341 XCTest + 46 swift-testing still green.

- [ ] **Step 6: Commit**

```bash
git add project.yml Tests/LoreFeatureTests/MarkdownDependencyTests.swift
git commit -m "build: add swift-markdown"
```

---

### Task 2: `SourceOffsetMap`

The single riskiest pure type in the milestone. If it is wrong, every feature above it styles the wrong characters — silently.

**Files:**
- Create: `Sources/LoreFeature/Logic/SourceOffsetMap.swift`
- Test: `Tests/LoreFeatureTests/SourceOffsetMapTests.swift`

**Interfaces:**
- Consumes: nothing (deliberately — it must be testable without the parser).
- Produces:
  - `public struct SourceOffsetMap: Sendable`
  - `public init(body: String, bodyUTF16Offset: Int)`
  - `public func utf16Offset(line: Int, column: Int) -> Int?` — 1-based line and column, **column counted in UTF-8 bytes** (cmark's unit); returns `nil` when the position does not exist.
  - `public func utf16Range(fromLine: Int, fromColumn: Int, toLine: Int, toColumn: Int) -> NSRange?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/SourceOffsetMapTests.swift`:

```swift
import XCTest
@testable import LoreFeature

final class SourceOffsetMapTests: XCTestCase {

    func test_firstCharacterOfFirstLine() {
        let map = SourceOffsetMap(body: "abc\ndef\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
    }

    func test_secondLineStartsAfterTheNewline() {
        let map = SourceOffsetMap(body: "abc\ndef\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 4)
    }

    func test_bodyOffsetShiftsEverything() {
        // The editor holds frontmatter + body; the parser only saw the body.
        let map = SourceOffsetMap(body: "abc\n", bodyUTF16Offset: 20)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 20)
    }

    func test_crlfLineEndingsAdvanceByTwoUTF16Units() {
        // "\r\n" is ONE Character but TWO UTF-16 code units. Getting this wrong
        // silently misplaces every span in a Windows-authored note.
        let map = SourceOffsetMap(body: "abc\r\ndef\r\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 5)
    }

    func test_crOnlyLineEndings() {
        let map = SourceOffsetMap(body: "abc\rdef\r", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 4)
    }

    func test_mixedLineEndings() {
        let map = SourceOffsetMap(body: "a\nb\r\nc\rd", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 2)
        XCTAssertEqual(map.utf16Offset(line: 3, column: 1), 5)
        XCTAssertEqual(map.utf16Offset(line: 4, column: 1), 7)
    }

    func test_multiByteScalarShiftsColumnsOnItsLine() {
        // "é" is 2 UTF-8 bytes but 1 UTF-16 unit. cmark columns count bytes.
        let map = SourceOffsetMap(body: "é x\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)   // é
        XCTAssertEqual(map.utf16Offset(line: 1, column: 3), 1)   // space (byte 3)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 4), 2)   // x
    }

    func test_emojiIsTwoUTF16Units() {
        // "👍" is 4 UTF-8 bytes and 2 UTF-16 units.
        let map = SourceOffsetMap(body: "👍x\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 5), 2)   // x
    }

    func test_emptyBody() {
        let map = SourceOffsetMap(body: "", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertNil(map.utf16Offset(line: 2, column: 1))
    }

    func test_finalLineWithoutTerminator() {
        let map = SourceOffsetMap(body: "abc\ndef", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 4), 7)
    }

    func test_outOfRangePositionsReturnNil() {
        let map = SourceOffsetMap(body: "abc\n", bodyUTF16Offset: 0)
        XCTAssertNil(map.utf16Offset(line: 0, column: 1))
        XCTAssertNil(map.utf16Offset(line: 99, column: 1))
        XCTAssertNil(map.utf16Offset(line: 1, column: 99))
    }

    func test_rangeSpansTwoLines() {
        let map = SourceOffsetMap(body: "abc\ndef\n", bodyUTF16Offset: 0)
        let r = map.utf16Range(fromLine: 1, fromColumn: 1, toLine: 2, toColumn: 4)
        XCTAssertEqual(r, NSRange(location: 0, length: 7))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "SourceOffsetMap|error:"`
Expected: FAIL — `cannot find 'SourceOffsetMap' in scope`.

- [ ] **Step 3: Create `SourceOffsetMap.swift`**

```swift
import Foundation

/// Converts cmark's 1-based line/column positions into UTF-16 offsets in the
/// EDITOR's string.
///
/// Three separate hazards make this non-trivial, and all three have bitten this
/// codebase before:
///
/// * **Line endings.** `"\r\n"` is ONE Swift `Character` but TWO UTF-16 code
///   units. A previous milestone found that `split(separator: "\n")` never
///   splits a CRLF document at all, so a Windows-authored note scanned as a
///   single line. Line starts are therefore found by scanning UTF-16 units,
///   not by splitting on Characters.
/// * **Columns are BYTES.** cmark counts UTF-8 bytes, not characters and not
///   UTF-16 units. `é` is 2 bytes / 1 unit; `👍` is 4 bytes / 2 units.
/// * **Frontmatter.** The parser sees the body; the editor holds the whole
///   file. `bodyUTF16Offset` shifts every result.
///
/// Out-of-range positions return `nil` rather than clamping. A dropped span is
/// invisible; a span applied to the wrong range is a visible defect and, if it
/// ever drove an edit, a destructive one.
public struct SourceOffsetMap: Sendable {
    /// UTF-16 offset (relative to the body) where each 1-based line begins.
    private let lineStarts: [Int]
    /// Per line, the UTF-16 offset of each 1-based UTF-8 byte column.
    private let columnTables: [[Int]]
    private let bodyUTF16Offset: Int
    private let bodyUTF16Length: Int

    public init(body: String, bodyUTF16Offset: Int) {
        self.bodyUTF16Offset = bodyUTF16Offset
        let units = Array(body.utf16)
        self.bodyUTF16Length = units.count

        var starts: [Int] = [0]
        var tables: [[Int]] = []
        var currentLineStart = 0
        var i = 0
        while i < units.count {
            let unit = units[i]
            let isCR = unit == 0x000D
            let isLF = unit == 0x000A
            if isCR || isLF {
                tables.append(Self.columnTable(of: units, from: currentLineStart, to: i))
                // CRLF counts as one line break spanning two UTF-16 units.
                if isCR, i + 1 < units.count, units[i + 1] == 0x000A { i += 1 }
                i += 1
                currentLineStart = i
                starts.append(currentLineStart)
                continue
            }
            i += 1
        }
        tables.append(Self.columnTable(of: units, from: currentLineStart, to: units.count))
        self.lineStarts = starts
        self.columnTables = tables
    }

    /// Maps each 1-based UTF-8 byte column on one line to a UTF-16 offset.
    ///
    /// Built by walking the line's scalars once: each scalar contributes its
    /// UTF-8 length in byte columns, all pointing at the UTF-16 offset where
    /// that scalar starts. A column landing mid-scalar therefore resolves to
    /// that scalar's start, which is the only sane answer.
    private static func columnTable(of units: [UInt16], from start: Int, to end: Int) -> [Int] {
        let slice = Array(units[start..<end])
        let line = String(decoding: slice, as: UTF16.self)
        var table: [Int] = []
        var utf16Offset = start
        for scalar in line.unicodeScalars {
            let byteCount = String(scalar).utf8.count
            let unitCount = String(scalar).utf16.count
            for _ in 0..<byteCount { table.append(utf16Offset) }
            utf16Offset += unitCount
        }
        // One past the end, so a column pointing at the line terminator maps.
        table.append(utf16Offset)
        return table
    }

    public func utf16Offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= columnTables.count, column >= 1 else { return nil }
        let table = columnTables[line - 1]
        guard column <= table.count else { return nil }
        return bodyUTF16Offset + table[column - 1]
    }

    public func utf16Range(fromLine: Int, fromColumn: Int,
                           toLine: Int, toColumn: Int) -> NSRange? {
        guard let lower = utf16Offset(line: fromLine, column: fromColumn),
              let upper = utf16Offset(line: toLine, column: toColumn),
              upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoreFeature/Logic/SourceOffsetMap.swift Tests/LoreFeatureTests/SourceOffsetMapTests.swift
git commit -m "feat(markdown): map cmark line/column positions to UTF-16 offsets"
```

---

### Task 3: `MarkdownDocumentModel` and code-region reporting

The model that everything else consumes. This task delivers the parse plus one derived product: the set of source regions that are *code* — which is what Task 4 needs to keep wikilinks out of code blocks.

**Files:**
- Create: `Sources/LoreFeature/Logic/MarkdownDocumentModel.swift`
- Test: `Tests/LoreFeatureTests/MarkdownSpanTests.swift`

**Interfaces:**
- Consumes: `SourceOffsetMap` (Task 2), `Frontmatter.bodyOffset`, the `Markdown` module (Task 1).
- Produces:
  - `public struct MarkdownDocumentModel: Sendable`
  - `public init(fullText: String)` — splits frontmatter itself, parses the body
  - `public var codeRangesUTF16: [NSRange]` — every fenced/indented code block and inline code span, in editor coordinates
  - `public func isInsideCode(utf16Offset: Int) -> Bool`
  - `public let offsetMap: SourceOffsetMap`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/MarkdownSpanTests.swift`:

```swift
import XCTest
@testable import LoreFeature

final class MarkdownDocumentModelTests: XCTestCase {

    func test_reportsFencedCodeAsCode() {
        let text = "before\n\n```\nlet x = 1\n```\n\nafter\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        let inside = ns.range(of: "let x = 1").location
        XCTAssertTrue(model.isInsideCode(utf16Offset: inside))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "before").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "after").location))
    }

    func test_reportsInlineCodeAsCode() {
        let text = "a `code` b\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "code").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "b").location))
    }

    func test_skipsFrontmatterWhenComputingOffsets() {
        let text = "---\nid: a\ntitle: T\n---\n\n```\ncode\n```\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "code").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "title").location))
    }

    func test_handlesCRLFDocuments() {
        let text = "before\r\n\r\n```\r\ncode\r\n```\r\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "code").location))
    }

    func test_emptyDocumentDoesNotCrash() {
        let model = MarkdownDocumentModel(fullText: "")
        XCTAssertTrue(model.codeRangesUTF16.isEmpty)
        XCTAssertFalse(model.isInsideCode(utf16Offset: 0))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "MarkdownDocumentModel|error:"`
Expected: FAIL — `cannot find 'MarkdownDocumentModel' in scope`.

- [ ] **Step 3: Create `MarkdownDocumentModel.swift`**

```swift
import Foundation
import Markdown

/// The one place this application parses markdown.
///
/// Before M2a there were THREE scanners — a regex styler, a line-based outline
/// scan, and the link parser's span scanner — and they disagreed: the first two
/// were blind to code fences, so a `#` comment in a code block became a heading
/// in the index and `**bold**` inside a fence was styled. Every feature that
/// reads document structure now derives from this single parse.
public struct MarkdownDocumentModel: Sendable {
    public let offsetMap: SourceOffsetMap
    public let codeRangesUTF16: [NSRange]
    private let document: Document

    public init(fullText: String) {
        let bodyStart = Frontmatter.bodyOffset(in: fullText)
        let body = String(fullText.dropFirst(bodyStart))
        let bodyUTF16Offset = (String(fullText.prefix(bodyStart)) as NSString).length

        let map = SourceOffsetMap(body: body, bodyUTF16Offset: bodyUTF16Offset)
        let doc = Document(parsing: body)

        self.offsetMap = map
        self.document = doc
        self.codeRangesUTF16 = Self.codeRanges(in: doc, map: map)
    }

    public func isInsideCode(utf16Offset offset: Int) -> Bool {
        codeRangesUTF16.contains { NSLocationInRange(offset, $0) }
    }

    /// Every fenced block, indented block, and inline code span.
    private static func codeRanges(in document: Document, map: SourceOffsetMap) -> [NSRange] {
        var collector = CodeRangeCollector(map: map)
        collector.visit(document)
        return collector.ranges
    }
}

/// Walks the AST collecting the source ranges of code.
///
/// A node whose `range` is nil contributes nothing rather than guessing — a
/// dropped range means a link inside that code is treated as a real link, which
/// is a visible wrong answer, whereas a GUESSED range could suppress a real
/// link silently. Neither is good; the visible one is preferable.
private struct CodeRangeCollector: MarkupWalker {
    let map: SourceOffsetMap
    var ranges: [NSRange] = []

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        append(codeBlock.range)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        append(inlineCode.range)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        append(html.range)
    }

    private mutating func append(_ sourceRange: SourceRange?) {
        guard let r = sourceRange,
              let ns = map.utf16Range(fromLine: r.lowerBound.line,
                                      fromColumn: r.lowerBound.column,
                                      toLine: r.upperBound.line,
                                      toColumn: r.upperBound.column) else { return }
        ranges.append(ns)
    }
}
```

**Note on API shape:** `MarkupWalker`'s visit methods and `SourceRange`'s member names must be checked against the resolved `swift-markdown` revision. If a method is named differently or `MarkupWalker` requires a class rather than a struct, adapt and **state the exact API you used in your report** — Tasks 4-6 build on it.

- [ ] **Step 4: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoreFeature/Logic/MarkdownDocumentModel.swift Tests/LoreFeatureTests/MarkdownSpanTests.swift
git commit -m "feat(markdown): parse once and report code regions from the AST"
```

---

### Task 4: Route wikilink extraction through the AST

The regression-gate task. M1's link layer closed six data-loss paths; this changes **how candidate text is found** and must not change **what counts as a link**.

**Files:**
- Modify: `Sources/LoreFeature/Logic/LinkParser.swift`
- Test: `Tests/LoreFeatureTests/LinkParserTests.swift` (existing — must pass unchanged)

**Interfaces:**
- Consumes: `MarkdownDocumentModel.isInsideCode(utf16Offset:)` (Task 3).
- Produces: `LinkParser.spans(in:)` keeps its exact signature and semantics. `DocumentLink`, `LinkSyntax`, and `LinkSpan` are **unchanged**.

**CRITICAL — read before writing any code:**
- `LinkSpan.targetRange` is **Character** offsets. `MarkdownDocumentModel` works in **UTF-16** offsets. Converting between them is exactly the class of bug that cost M1 review rounds. Convert at one clearly-named boundary, and state the unit in every local variable's name.
- `LinkParser.spans(in:)` is called with the **body**, not the full text, by some callers and with full text by others — check every call site before assuming.
- Do NOT change the wikilink grammar, the markdown-link grammar, percent-decoding, `resolutionTarget`, or the fragment/alias handling.

- [ ] **Step 1: Run the existing suite and record the baseline**

Run: `make test 2>&1 | grep -E "LinkParserTests|Executed"`
Record the exact pass count. This is your gate: it must be identical at the end.

- [ ] **Step 2: Write the failing test for the new equivalence**

Append to `Tests/LoreFeatureTests/LinkParserTests.swift`:

```swift
func test_astAndScannerAgreeOnEveryFixture() {
    // The AST must classify code regions exactly as the hand-written scanner
    // did. Any disagreement is a behaviour change in the link graph, which is
    // what this task exists NOT to do.
    let fixtures = [
        "see [[One]]\n\n```\n[[Two]]\n```\n\n[[Three]]\n",
        "`[[Inline]]` but [[Real]]\n",
        "~~~\n[[Fenced]]\n~~~\n[[After]]\n",
        "````\n```\n[[StillCode]]\n```\n````\n[[Outside]]\n",
        "text [[A|display]] and [[B#Heading]] and ![[C]]\n",
        "[md](Design%20Doc.md) and [ext](https://example.com)\n",
        "---\nid: a\ntitle: T\n---\n[[InBody]]\n",
    ]
    for fixture in fixtures {
        let targets = LinkParser.links(in: fixture).map(\.rawTarget)
        XCTAssertFalse(targets.contains("Two"), fixture)
        XCTAssertFalse(targets.contains("Inline"), fixture)
        XCTAssertFalse(targets.contains("Fenced"), fixture)
        XCTAssertFalse(targets.contains("StillCode"), fixture)
    }
}
```

- [ ] **Step 3: Run to verify it passes already**

Run: `make test 2>&1 | grep -E "astAndScanner"`
Expected: PASS — the current scanner already handles these. That is the point: this test pins current behaviour *before* you change the implementation, so it can catch a regression during the swap.

- [ ] **Step 4: Route region detection through the model**

In `LinkParser`, replace the hand-written fence/inline-code tracking with a query against `MarkdownDocumentModel`. Keep the bracket-grammar scanning exactly as it is — it is what finds `[[`, `|`, `#`, `![[`, and `[text](target)`. Only the "is this position inside code?" decision changes source.

Convert units at one boundary. Suggested shape, with the unit stated in every name:

```swift
    /// Character offset → UTF-16 offset, computed once per scan.
    ///
    /// `LinkSpan.targetRange` is in CHARACTERS (it indexes the string handed to
    /// this parser); `MarkdownDocumentModel` answers in UTF-16 units. Mixing
    /// them silently misplaces every span in a document containing an emoji.
    private static func utf16Offsets(for text: String) -> [Int] {
        var offsets: [Int] = []
        var running = 0
        for character in text {
            offsets.append(running)
            running += String(character).utf16.count
        }
        offsets.append(running)
        return offsets
    }
```

- [ ] **Step 5: Run the whole suite — the gate**

Run: `make test 2>&1 | tail -30`
Expected: PASS, with the `LinkParserTests` count **identical to the baseline from Step 1**. If any existing link test changed behaviour, stop and report it rather than adjusting the test — that test is the contract.

- [ ] **Step 6: Commit**

```bash
git add Sources/LoreFeature/Logic/LinkParser.swift Tests/LoreFeatureTests/LinkParserTests.swift
git commit -m "refactor(links): take code regions from the AST, grammar unchanged"
```

---

### Task 5: Style spans from the AST, and delete `MarkdownStyler`

**Files:**
- Create: `Sources/LoreFeature/Logic/MarkdownSpanBuilder.swift`
- Modify: `Sources/LoreFeature/Logic/MarkdownDocumentModel.swift`
- Delete: `Sources/LoreFeature/Logic/MarkdownStyler.swift`
- Test: `Tests/LoreFeatureTests/MarkdownSpanTests.swift`

**Interfaces:**
- Consumes: `MarkdownDocumentModel`, `SourceOffsetMap`.
- Produces:
  - `StyleSpan.Kind` gains: `.strong`, `.emphasis`, `.inlineCode`, `.codeBlock(language: String?)`, `.wikilink`, `.listItem`, `.blockQuote`. Existing cases `.heading(Int)`, `.link`, `.checkbox(Bool)` keep their names. `.bold`, `.italic`, `.code` are renamed to `.strong`, `.emphasis`, `.inlineCode` — update the editor's switch.
  - `StyleSpan.range` stays **UTF-16 offsets into the editor's string**. Say so in the declaration.
  - `MarkdownDocumentModel.styleSpans: [StyleSpan]`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LoreFeatureTests/MarkdownSpanTests.swift`:

```swift
final class MarkdownStyleSpanTests: XCTestCase {
    private func kinds(_ text: String) -> [StyleSpan.Kind] {
        MarkdownDocumentModel(fullText: text).styleSpans.map(\.kind)
    }

    func test_headingCarriesItsLevel() {
        XCTAssertTrue(kinds("## Two\n").contains(.heading(2)))
    }

    func test_strongAndEmphasis() {
        let k = kinds("**bold** and *italic*\n")
        XCTAssertTrue(k.contains(.strong))
        XCTAssertTrue(k.contains(.emphasis))
    }

    func test_codeBlockCarriesItsLanguage() {
        let k = kinds("```swift\nlet x = 1\n```\n")
        XCTAssertTrue(k.contains(.codeBlock(language: "swift")))
    }

    func test_nothingInsideAFenceIsStyledAsProse() {
        // The bug this milestone exists to fix: the regex styler bolded this.
        let spans = MarkdownDocumentModel(fullText: "```\n**not bold** # not heading\n```\n").styleSpans
        XCTAssertFalse(spans.contains { $0.kind == .strong })
        XCTAssertFalse(spans.contains { if case .heading = $0.kind { return true }; return false })
    }

    func test_taskCheckboxStateIsReported() {
        let k = kinds("- [ ] open\n- [x] done\n")
        XCTAssertTrue(k.contains(.checkbox(false)))
        XCTAssertTrue(k.contains(.checkbox(true)))
    }

    func test_spanRangesAreValidUTF16RangesIntoTheFullText() {
        let text = "---\nid: a\n---\n# 👍 Title\n"
        let ns = text as NSString
        for span in MarkdownDocumentModel(fullText: text).styleSpans {
            XCTAssertGreaterThanOrEqual(span.range.lowerBound, 0)
            XCTAssertLessThanOrEqual(span.range.upperBound, ns.length,
                                     "a span past the end would crash the text view")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "MarkdownStyleSpan|error:"`
Expected: FAIL — `styleSpans` does not exist and the new `Kind` cases do not exist.

- [ ] **Step 3: Move `StyleSpan` and extend its kinds**

Move `StyleSpan` out of `MarkdownStyler.swift` into `MarkdownSpanBuilder.swift`, extend `Kind`, and document the offset unit:

```swift
public struct StyleSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(Int)
        case strong
        case emphasis
        case inlineCode
        case codeBlock(language: String?)
        case link
        case wikilink
        case listItem
        case blockQuote
        case checkbox(Bool)
    }
    /// UTF-16 offsets into the EDITOR's full string, frontmatter included.
    /// Not Character offsets — `LinkSpan.targetRange` uses those, and mixing
    /// the two misplaces every span in a document containing an emoji.
    public let range: Range<Int>
    public let kind: Kind
}
```

- [ ] **Step 4: Build the spans with an AST walk**

Write `MarkdownSpanBuilder` as a `MarkupWalker` mirroring `CodeRangeCollector`'s shape: visit `Heading`, `Strong`, `Emphasis`, `InlineCode`, `CodeBlock`, `Link`, `ListItem` (reading its `checkbox`), and `BlockQuote`; map each node's `range` through `SourceOffsetMap`; drop any node whose range fails to map. Add `styleSpans` to `MarkdownDocumentModel`, computed in `init` alongside `codeRangesUTF16` from the same parse.

Wikilinks are not AST nodes — emit `.wikilink` spans from `LinkParser.spans(in:)` filtered to `syntax == .wikilink`, converting their Character ranges to UTF-16 at the same single boundary Task 4 established.

- [ ] **Step 5: Delete `MarkdownStyler` and update the editor's switch**

```bash
git rm Sources/LoreFeature/Logic/MarkdownStyler.swift
```

In `MarkdownEditor.applyStyles()`, change `MarkdownStyler.spans(in: tv.string)` to the model's `styleSpans` and update the `switch` for the renamed and new cases. Styling appearance is Task 6's concern; here, just keep it compiling and green.

- [ ] **Step 6: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS. Every `LinkParserTests` case still green.

- [ ] **Step 7: Commit**

```bash
git add -A Sources/LoreFeature/Logic Sources/LoreFeature/Views/MarkdownEditor.swift Tests/LoreFeatureTests/MarkdownSpanTests.swift
git commit -m "feat(markdown): derive style spans from the AST, delete the regex styler"
```

---

### Task 6: In-place rendering, debounced parse, clear-before-apply

**Files:**
- Modify: `Sources/LoreFeature/Views/MarkdownEditor.swift`
- Test: `Tests/LoreFeatureTests/MarkdownStylingBenchmark.swift`

**Interfaces:**
- Consumes: `MarkdownDocumentModel.styleSpans`.
- Produces: no new public API. The editor gains a debounced parse and a cached model.

- [ ] **Step 1: Write the failing benchmark**

Create `Tests/LoreFeatureTests/MarkdownStylingBenchmark.swift`, following the existing `LoreRebuildBenchmark` for shape:

```swift
import XCTest
@testable import LoreFeature

final class MarkdownStylingBenchmark: XCTestCase {

    /// The property that matters: parse count is bounded by the DEBOUNCE, not
    /// by the number of characters typed. Before M2a the styler ran a full
    /// regex sweep per keystroke; an AST parse per keystroke would be worse.
    func test_parsingALargeDocumentIsFastEnoughToDebounce() {
        let paragraph = "Some **bold** text with a [[Link]] and `code`.\n\n"
        let body = String(repeating: paragraph, count: 5_000)   // ~230 KB
        XCTAssertGreaterThan((body as NSString).length, 200_000)

        measure {
            _ = MarkdownDocumentModel(fullText: body).styleSpans
        }
    }

    func test_aDocumentOverTheHardCapProducesNoSpans() {
        let body = String(repeating: "x", count: MarkdownDocumentModel.stylingHardCap + 1)
        XCTAssertTrue(MarkdownDocumentModel(fullText: body).styleSpans.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "stylingHardCap|error:"`
Expected: FAIL — `stylingHardCap` does not exist.

- [ ] **Step 3: Add the caps**

In `MarkdownDocumentModel`:

```swift
    /// Above this much body text, styling covers only the visible range plus a
    /// margin, re-derived on scroll. The outline and task lists still come from
    /// a full parse, which happens once per debounce rather than per keystroke.
    public static let stylingViewportCap = 256 * 1024

    /// Above this, styling is disabled entirely and the editor says so. A note
    /// that is slow to type in is worse than one that is plainly styled.
    public static let stylingHardCap = 2 * 1024 * 1024
```

Return `[]` from `styleSpans` above `stylingHardCap`.

- [ ] **Step 4: Debounce the parse and shift spans between parses**

In `MarkdownEditor`'s coordinator:
- Cache the last `MarkdownDocumentModel` and the spans derived from it.
- On text change, cancel and re-arm a ~150ms timer; only the timer's firing re-parses.
- Between parses, shift every cached span whose range starts after the edit location by the edit's UTF-16 delta, so styling stays visually stable rather than flickering off and back.
- Keep the existing `applyStyles` call sites; they now consume cached spans.

- [ ] **Step 5: Clear before applying**

`applyStyles` already calls `setAttributes` over the full range, which clears. Confirm it still does after the span-kind changes, and that the styled range covers the whole string — a stale bold attribute surviving an edit is the failure this guards.

- [ ] **Step 6: Render the new kinds**

Extend the `switch`: `.strong` bold; `.emphasis` italic; `.inlineCode` and `.codeBlock` monospaced with `accentSecondary` and a subtle background; `.link` and `.wikilink` `accentPrimary` (underline links only); `.blockQuote` muted foreground with a head indent; `.listItem` unchanged foreground; `.heading(level)` the existing size ramp; `.checkbox` `accentTertiary`.

- [ ] **Step 7: Verify M1's editor features still work**

Reason through, and state in your report, that `[[` autocomplete's caret tracking and Cmd-click's target resolution still behave when styling lags the text by a frame. Both read `tv.string` and the caret directly, not the spans — confirm that is still true after your change.

- [ ] **Step 8: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/LoreFeature/Views/MarkdownEditor.swift Sources/LoreFeature/Logic/MarkdownDocumentModel.swift Tests/LoreFeatureTests/MarkdownStylingBenchmark.swift
git commit -m "feat(editor): debounced AST styling with size caps"
```

---

### Task 7: Outline from the AST, and the outline section

**Files:**
- Modify: `Sources/LoreFeature/Logic/MarkdownDocumentModel.swift`
- Modify: `Sources/LoreFeature/Documents/Markdown/MarkdownEngine.swift`
- Create: `Sources/LoreFeature/Views/OutlineSection.swift`
- Modify: `Sources/LoreFeature/Views/DocumentPane.swift`
- Test: `Tests/LoreFeatureTests/MarkdownSpanTests.swift`, `Tests/LoreFeatureTests/EngineConformanceTests.swift`

**Interfaces:**
- Consumes: `MarkdownDocumentModel`.
- Produces:
  - `OutlineEntry` (existing, from M0) gains `public let utf16Offset: Int`.
  - `MarkdownDocumentModel.outline: [OutlineEntry]`
  - `struct OutlineSection: View`
  - `MarkdownEngine.outline(of:)` is **deleted**.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LoreFeatureTests/MarkdownSpanTests.swift`:

```swift
final class MarkdownOutlineTests: XCTestCase {
    func test_listsHeadingsWithLevels() {
        let outline = MarkdownDocumentModel(fullText: "# One\n\n## Two\n\n### Three\n").outline
        XCTAssertEqual(outline.map(\.level), [1, 2, 3])
        XCTAssertEqual(outline.map(\.text), ["One", "Two", "Three"])
    }

    func test_aHashInsideAFenceIsNotAHeading() {
        // Shipping bug: `MarkdownEngine.outline` counted this as a heading and
        // it reached the index.
        let outline = MarkdownDocumentModel(fullText: "# Real\n\n```\n# Not a heading\n```\n").outline
        XCTAssertEqual(outline.map(\.text), ["Real"])
    }

    func test_offsetsPointAtTheHeadingInTheFullText() {
        let text = "---\nid: a\n---\n# Title\n"
        let outline = MarkdownDocumentModel(fullText: text).outline
        let ns = text as NSString
        XCTAssertEqual(outline.first?.utf16Offset, ns.range(of: "# Title").location)
    }
}
```

Append to `Tests/LoreFeatureTests/EngineConformanceTests.swift`:

```swift
func test_markdownIndexPayloadOutlineExcludesCodeFences() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lore-outline-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("n.md")
    try "---\nid: a\ntitle: T\n---\n# Real\n\n```\n# Fake\n```\n"
        .write(to: url, atomically: true, encoding: .utf8)
    let engine = try MarkdownEngine.load(url)
    XCTAssertEqual(engine.indexPayload.outline.map(\.text), ["Real"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "Outline|error:"`
Expected: FAIL — `outline` does not exist on the model; the conformance test fails because the current line scanner returns `["Real", "Fake"]`.

- [ ] **Step 3: Add `utf16Offset` to `OutlineEntry` and build the outline**

Add the stored property with a defaulted initializer parameter so existing construction sites keep compiling. Collect `Heading` nodes in the same walk as Task 5's spans — one traversal, not two.

- [ ] **Step 4: Delete `MarkdownEngine.outline(of:)`**

Replace its use in `indexPayload` with `MarkdownDocumentModel(fullText:).outline`. Note the engine holds a `Note`, so build the model from the note's full serialized text or from body + frontmatter offset — whichever keeps offsets consistent with the editor. State which you chose and why.

- [ ] **Step 5: Create `OutlineSection.swift` and host it**

A collapsible list of the open document's headings, indented by level, in `DocumentPane` alongside `BacklinksPanel`. Clicking an entry scrolls the editor to `utf16Offset` — add a scroll-to-offset entry point on `MarkdownEditor` rather than reaching into its internals from the view. Persist collapsed state via `PluginDocumentStore`, following how `BacklinksPanel`'s state is persisted in `LoreStore`.

- [ ] **Step 6: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A Sources/LoreFeature Tests/LoreFeatureTests
git commit -m "feat(markdown): outline from the AST with scroll-to offsets"
```

---

### Task 8: Task checkboxes

**Files:**
- Create: `Sources/LoreFeature/Logic/MarkdownTaskItems.swift`
- Modify: `Sources/LoreFeature/Logic/MarkdownDocumentModel.swift`
- Modify: `Sources/LoreFeature/Views/MarkdownEditor.swift`
- Test: `Tests/LoreFeatureTests/MarkdownTaskTests.swift`

**Interfaces:**
- Consumes: `MarkdownDocumentModel`, `DocumentSession`.
- Produces:
  - `public struct TaskItem: Equatable, Sendable { public let isChecked: Bool; public let markerRangeUTF16: NSRange }` — `markerRangeUTF16` covers exactly the character between the brackets.
  - `MarkdownDocumentModel.taskItems: [TaskItem]`
  - `MarkdownDocumentModel.toggle(_ item: TaskItem, in fullText: String) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LoreFeatureTests/MarkdownTaskTests.swift`:

```swift
import XCTest
@testable import LoreFeature

final class MarkdownTaskTests: XCTestCase {

    func test_findsCheckedAndUncheckedItems() {
        let items = MarkdownDocumentModel(fullText: "- [ ] a\n- [x] b\n").taskItems
        XCTAssertEqual(items.map(\.isChecked), [false, true])
    }

    func test_markerRangeCoversExactlyOneCharacter() {
        let text = "- [ ] a\n"
        let item = MarkdownDocumentModel(fullText: text).taskItems[0]
        XCTAssertEqual(item.markerRangeUTF16.length, 1)
        XCTAssertEqual((text as NSString).substring(with: item.markerRangeUTF16), " ")
    }

    func test_togglingChangesExactlyOneCharacter() {
        let text = "- [ ] a\n- [x] b\n"
        let model = MarkdownDocumentModel(fullText: text)
        let toggled = model.toggle(model.taskItems[0], in: text)
        XCTAssertEqual(toggled, "- [x] a\n- [x] b\n")
        XCTAssertEqual(toggled.count, text.count)
    }

    func test_togglingBackRestoresTheOriginal() {
        let text = "- [x] a\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(model.toggle(model.taskItems[0], in: text), "- [ ] a\n")
    }

    func test_ignoresCheckboxLookalikesInsideAFence() {
        let items = MarkdownDocumentModel(fullText: "```\n- [ ] not a task\n```\n").taskItems
        XCTAssertTrue(items.isEmpty)
    }

    func test_worksWithFrontmatterPresent() {
        let text = "---\nid: a\n---\n- [ ] a\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(model.toggle(model.taskItems[0], in: text), "---\nid: a\n---\n- [x] a\n")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "MarkdownTask|error:"`
Expected: FAIL — `taskItems` does not exist.

- [ ] **Step 3: Implement `TaskItem`, `taskItems`, and `toggle`**

Collect `ListItem` nodes carrying a `checkbox` in the shared walk. Derive `markerRangeUTF16` from the item's range plus the fixed `- [` prefix width — but verify against the actual text at that offset rather than trusting arithmetic, and drop the item if the character there is not `" "` or `"x"`. `toggle` returns a new string with that one character replaced.

- [ ] **Step 4: Wire the click through the edit path**

In `MarkdownEditor`, a click landing inside a checkbox marker range toggles it by replacing that one character **through the same text-mutation path a keystroke uses** — so it lands in the undo stack, marks the session dirty, and is picked up by the debounced autosave and the external-change guard. Do NOT write the file directly and do NOT call `saveNow()`.

- [ ] **Step 5: Write the store-level test**

Append to `Tests/LoreFeatureTests/MarkdownTaskTests.swift` a test that opens a session on a note with `- [ ] a`, applies the toggle through the engine's note body the way the editor does, marks changed, waits past the autosave debounce, and asserts the file on disk contains `- [x] a` and the session is no longer dirty. Follow `DocumentSessionTests` for the session-construction pattern.

- [ ] **Step 6: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LoreFeature Tests/LoreFeatureTests/MarkdownTaskTests.swift
git commit -m "feat(markdown): interactive task checkboxes through the edit path"
```

---

### Task 9: Code block presentation

**Files:**
- Modify: `Sources/LoreFeature/Views/MarkdownEditor.swift`
- Test: `Tests/LoreFeatureTests/MarkdownSpanTests.swift`

**Interfaces:**
- Consumes: `StyleSpan.Kind.codeBlock(language:)`.
- Produces: no new API.

- [ ] **Step 1: Write the failing test**

```swift
func test_codeBlockSpanReportsItsInfoString() {
    let spans = MarkdownDocumentModel(fullText: "```swift\nlet x = 1\n```\n").styleSpans
    let langs: [String?] = spans.compactMap {
        if case .codeBlock(let language) = $0.kind { return language }
        return nil
    }
    XCTAssertEqual(langs, ["swift"])
}

func test_codeBlockWithoutAnInfoStringHasNoLanguage() {
    let spans = MarkdownDocumentModel(fullText: "```\nplain\n```\n").styleSpans
    let langs: [String?] = spans.compactMap {
        if case .codeBlock(let language) = $0.kind { return language }
        return nil
    }
    XCTAssertEqual(langs, [String?.none])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E "codeBlock|error:"`
Expected: FAIL if Task 5 stored the info string differently; PASS if already correct — in which case say so and proceed to Step 3.

- [ ] **Step 3: Render the block**

Monospaced font, a subtle background colour over the block's range, and the language rendered as a trailing label attribute on the opening fence line. **No per-token colouring** — that is explicitly out of scope; adding a tokenizer here would reintroduce exactly the hand-rolled scanning this milestone removes.

- [ ] **Step 4: Run tests**

Run: `make generate && make test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoreFeature/Views/MarkdownEditor.swift Tests/LoreFeatureTests/MarkdownSpanTests.swift
git commit -m "feat(editor): code block background and language label"
```

---

### Task 10: Verify the M2a success criteria

**Files:** none created; verification, plus small clearly-scoped fixes only.

- [ ] **Step 1: Criterion 1 — one parser**

```bash
rg -n "MarkdownStyler|func outline\(of" Sources/ || echo "clean"
rg -c "NSRegularExpression" Sources/LoreFeature/Logic/ || echo "no regex scanners"
```

Expected: `MarkdownStyler` and `MarkdownEngine.outline(of:)` are gone. Report any remaining regex-based markdown scanning and judge whether it is markdown structure (a defect) or something else.

- [ ] **Step 2: Criterion 2 — the link regression gate**

Run: `make test 2>&1 | grep -E "LinkParserTests|LinkRewriter|LinkEncoding|Executed"`
Expected: every M1 link suite green with counts unchanged from the branch point.

- [ ] **Step 3: Criterion 3 — code fences are inert**

Build a scratch note under `/tmp` containing, inside a fence, a `#` heading, a `**bold**` run, a `[[link]]`, and a `- [ ]` task. Assert at store level: no outline entry, no style span, no graph entry, no task item.

- [ ] **Step 4: Criteria 4-6 — rendering, outline, tasks**

`make sideload`, open Lore on a scratch vault. **Do not touch the main Ainkrad host** — the owner runs it in a parallel session; DevPlugins is the approved target. Confirm headings/emphasis/code/links/quotes/lists render with markers visible; the outline lists headings and clicking scrolls; a checkbox toggles, is undoable, and reaches disk.

- [ ] **Step 5: Criterion 7 — offsets**

Verify at store level with a CRLF note, an emoji note, and a note with frontmatter: spans land on the intended characters.

- [ ] **Step 6: Criterion 8 — responsiveness**

Run: `make test 2>&1 | grep -E "MarkdownStylingBenchmark|measured"`
Report the measured figures rather than asserting responsiveness.

- [ ] **Step 7: Criterion 9 — tests and sizes**

```bash
make test 2>&1 | tail -20
wc -l Sources/LoreFeature/**/*.swift | sort -rn | head -8
```

- [ ] **Step 8: Report**

Evidence per criterion — exact steps, actual output, PASS/FAIL/PARTIAL. State plainly anything the GUI prevented you from verifying. No commit unless a fix was needed.

---

## Self-Review Notes

Checked against the spec:

- **Parser adoption, three scanners retired** — Tasks 1, 4, 5, 7. Covered.
- **Wikilink grammar unchanged; M1 suite as the gate** — Task 4 Steps 1 and 5. Covered.
- **`SourceOffsetMap` with the adversarial set** — Task 2. Covered.
- **Style spans, kinds, markers visible, clear-before-apply** — Tasks 5, 6. Covered.
- **Debounce, share one parse, explicit caps** — Task 6 Steps 3-4; caps are named constants. Covered.
- **M1 editor features unaffected** — Task 6 Step 7 requires reasoning it through. Covered.
- **Outline: index + sidebar, scroll to a real range** — Task 7. Covered.
- **Tasks toggle through the edit path** — Task 8 Steps 4-5. Covered.
- **Code blocks: monospace, background, label, no tokenizing** — Task 9. Covered.
- **Failure modes** — parse failure keeps previous spans (Task 6's cache), unmappable location dropped (Task 2's `nil` contract, honoured in Task 3's collector), malformed task dropped (Task 8 Step 3), caps (Task 6), frontmatter shift (Tasks 2, 3). Covered.
- **All nine success criteria** — Task 10. Covered.

**Known risks, recorded rather than hidden:**

- **`swift-markdown`'s exact API is not pinned in this plan.** Task 1 Step 4 and Task 3's note require the implementer to verify visitor names, `SourceRange` members, and whether ranges need a parse option, then report what they used. Writing confident-but-wrong signatures here would be worse: M0 and M1 both had defects that originated in plan code asserting an API it had not checked.
- **The Character-vs-UTF-16 boundary in Task 4** is the highest-risk edit in the milestone. It is why Task 4's gate is "the existing suite passes with an identical count", not "the tests pass".
- **`MarkdownEditor.swift` is 338 lines** and Tasks 6, 8 and 9 all add to it. If it approaches 500, split the coordinator out — say so rather than crowding the file.
