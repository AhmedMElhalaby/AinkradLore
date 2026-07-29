# Lore M0 — Document-Engine Architecture

**Date:** 2026-07-29
**Status:** Design approved, pending spec review
**Milestone:** M0 of the Lore document-workstation roadmap

## Context

AinkradLore today is a markdown note app: a flat vault of `.md` files with YAML
frontmatter, a GRDB/FTS5 index, tag filtering, a single-note editor pane, a
folder watcher, and an MCP server exposing note operations to the assistant.
About 1,800 lines across `Sources/LoreFeature`.

The product goal is larger: Lore becomes the main document application,
replacing the roles currently split across a text editor, Apple Notes,
Obsidian, Notion, a PDF viewer, and Pages. Those six roles reduce to four
document engines — markdown/plain text, rich text, structured databases, and
PDF — plus a shell that owns the vault, index, search, linking, tabs, and agent
surface.

Every hardcoded assumption that "a document is a markdown file" therefore has
to come out of the shell before any other milestone can land. That is M0.

### Format position

Lore-native is the source of truth; markdown is a first-class peer, not a
degraded export. Obsidian interoperability is preserved for markdown documents
and not attempted for anything Obsidian could never render.

## Roadmap position

| Milestone | Scope |
|---|---|
| **M0** | Document-engine architecture, tabs, lossless frontmatter *(this spec)* |
| M1 | Structure & linking: folders, wikilinks, backlinks, safe rename/move, trash |
| M2 | Markdown editing depth: preview, outline, tasks, highlighting, find/replace |
| M3 | PDF engine: view, outline, indexed text, annotations |
| M4 | Rich-text engine (Apple-Notes class), `.lore` package implementation |
| M5 | Properties & views (Notion tier): typed schema, table/board/calendar |
| M6 | Agent surface depth: structured queries, graph traversal, safe edits |
| M7 | Workflow polish: templates, daily notes, global capture, pins, multi-window |

## On-disk format

Two peer formats. No automatic conversion between them.

### `Name.lore/` — Lore-native document package

A directory bundle presented to the user as a single document.

```
Name.lore/
  content.json    typed document model (engine-defined schema)
  meta.json       id, created, updated, properties, provenance
  assets/         images and attachments referenced by content.json
```

A package rather than a single file so assets stream rather than inflate the
document, diffs stay reviewable, and a corrupt asset cannot take the document
with it.

This is where rich text, database views, and PDF annotations live — structure
markdown cannot carry.

**M0 defines this layout but ships no code for it.** The first engine that
needs it (M3 or M4) implements `LorePackage` read/write. The layout is recorded
here so that engine does not reinvent it.

### `Name.md` — markdown

Plain markdown with YAML frontmatter, read and written verbatim, safe to open
in Obsidian. Not an export of a `.lore` document — an equal document type that
some documents simply are.

### Conversion

`Convert to Lore document` and `Export as Markdown` are explicit user actions.
Never automatic on save: automatic mirroring doubles every write, and once the
two copies disagree one of them has to be declared the loser.

## Architecture

### Document engines

```swift
protocol DocumentEngine {
    static var identifier: String { get }
    static func canOpen(_ url: URL) -> Bool          // UTType + extension
    static func load(_ url: URL) throws -> LoreDocument
    func save(to url: URL) throws
    var indexPayload: IndexPayload { get }
    @MainActor func makeEditor(_ ctx: EditorContext) -> AnyView
}
```

`IndexPayload` carries title, plaintext, tags, properties, outline, and links.
The shell talks only to `DocumentEngine` and `IndexPayload`; it never inspects a
document's internals or re-reads its file to index it. That indirection is what
lets a PDF or a `.lore` package contribute searchable text it does not literally
contain as bytes.

Every later milestone is then "add an engine," not "modify the shell."

**M0 ships two engines:**

- **Markdown** — the current code refactored behind the protocol. Behavior-preserving.
- **Plain text / code** — cheap to build, and it proves the abstraction is not
  secretly markdown-shaped.

### Component split

`LoreStore` is 279 lines doing four jobs; tabs plus engines would push it past
the 500-line limit. It splits into three, with `LoreStore` retained as the thin
facade the UI binds to.

- **`VaultIndexCoordinator`** — vault root, `FolderWatcher`, coalesced
  background rescan, `LoreIndex`. Scans for any engine-openable file, not just
  `.md`. The existing off-actor rebuild machinery moves here **intact** — it is
  the most carefully tuned code in the project and is relocated, not rewritten.
- **`DocumentSession`** — one per open tab. Holds the loaded `LoreDocument` and
  its engine, the mtime baseline, dirty state, and autosave debounce. The
  external-change guard moves here and now applies to every document type.
- **`LoreStore`** — vault selection, tab list, routing open/close/create
  through the engine registry. Facade only.

### Index generalization

The `notes` table becomes `documents`, adding:

- `type` — engine identifier
- `properties` — JSON blob of frontmatter/meta properties
- `plaintext` — engine-provided searchable text (what FTS indexes)

The existing standalone-FTS5 approach carries over unchanged, including the
`ftsExpression` sanitizer and the single-transaction `replaceAll`.

**Migration:** the index gains a `user_version`. On mismatch the index file is
deleted and rebuilt from disk. Safe because the index is derived state — there
is no migration SQL to get wrong, and the background rebuild already exists.

### Lossless frontmatter

`Frontmatter.serialize` currently rewrites the block from a fixed five-key
template (`id`, `title`, `tags`, `created`, `updated`). Every other key —
Obsidian's `aliases` and `cssclasses`, the Ainkrad pipeline's `status`,
`source`, and `type` — is silently deleted on the first save.

`Frontmatter` gains `extra: [(key: String, rawValue: String)]` — an *ordered*
list capturing every unmodelled key with its value's raw source text, re-emitted
verbatim on serialize in its original position relative to the modelled keys.

Ordered pairs rather than a dictionary, and raw text rather than parsed values,
because the requirement is round-trip fidelity, not comprehension: a
dictionary loses key order, and parsing a YAML array or block scalar into a
Swift type only to re-render it guarantees eventual drift. Lore preserves what
it does not model; it does not attempt to understand it. Typed property parsing
arrives in M5, where views actually need it.

This is a prerequisite, not an enhancement: M1's rename-rewrites-inbound-links
pass touches many files at once, and without this it would strip properties
across the whole vault in a single operation.

### Shell

Tabs (⌘T new, ⌘W close, ⌘1–9 select). "Main app for everything" cannot mean one
document at a time. Single window in M0; multi-window is M7.

## Data flow

**Opening:**

```
row/URL → EngineRegistry.engine(for:) → engine.load(url) → DocumentSession
        → tab appended → engine.makeEditor(ctx) → SwiftUI pane
```

**Saving:**

```
editor mutates document → session marks dirty → 500ms debounce
        → mtime check (conflict? → banner, no write)
        → engine.save(to:) → engine.indexPayload → index.upsert
        → watcher suppressed 1s (existing self-write echo guard)
```

## Failure modes

The rule is degrade, never block.

| Condition | Behavior |
|---|---|
| No engine claims the file | Read-only fallback viewer (text preview or file-metadata card) with *Open in Finder*. A vault containing `.xlsx` must not make the file list lie about what is there. |
| `load` throws (corrupt package, bad encoding) | Tab opens in an error state showing the reason plus *Reveal in Finder*. Never a silent empty document. |
| External change since load | Save refused; banner offers *Reload* / *Overwrite* / *Save a copy*. Today the error is thrown and the UI has no affordance for it — this is an M0 fix, not a port. |
| Index write fails | Logged; search degrades; the document still saves. The file is truth, the index is derived. |

## Testing

### Generic engine conformance suite

One set of tests run against every registered engine, so M3–M5 engines inherit
them by registering:

- load → save → load is byte-stable for an unmodified document (this is the
  test that catches the frontmatter-stripping bug)
- `canOpen` is mutually exclusive across engines for any given URL
- `indexPayload` is non-throwing and well-formed for valid, empty, and
  adversarial documents (very large, binary content in a text extension,
  zero-byte)

### Targeted tests

- Golden frontmatter round-trip: unknown keys, array values, multi-line values,
  key order preservation
- Mixed-type vault scan: `.md`, `.txt`, `.swift`, `.pdf`, unknown extension
- Tab lifecycle: open, close, select, dirty-on-close
- External-change conflict: each of reload, overwrite, save-a-copy
- Index migration: an index at the old `user_version` is rebuilt, not read

### Regression

All ten existing test files stay green throughout. The markdown engine
extraction is behavior-preserving by definition; a red existing test means the
refactor changed behavior.

## Explicitly out of scope for M0

- `LorePackage` read/write implementation (deferred to M3/M4)
- Wikilinks, backlinks, folder hierarchy (M1)
- Markdown preview and outline (M2)
- Multi-window, split panes (M7)
- Any change to the MCP server beyond keeping it compiling against the
  refactored store (M6 owns its expansion)

## Success criteria

1. The shell contains no reference to markdown, `.md`, or `Note` outside the
   markdown engine.
2. A vault containing markdown, plain text, source files, and unknown types
   lists, scans, and searches without error.
3. Saving a note with Obsidian and Ainkrad-pipeline frontmatter properties
   preserves every key.
4. Two documents can be open in tabs simultaneously, each with independent
   dirty and conflict state.
5. All existing tests pass; the conformance suite passes for both shipped
   engines.
6. No source file exceeds 500 lines.
