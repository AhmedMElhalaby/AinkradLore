# Lore M1 — Structure and Linking

**Date:** 2026-07-29
**Status:** Design approved, pending spec review
**Milestone:** M1 of the Lore document-workstation roadmap
**Predecessor:** M0 — document-engine architecture (merged, PR #8)

## Context

M0 replaced the "a document is a markdown file" assumption with a document-engine
registry. The shell — vault, index, search, tabs, agent surface — now talks only
to `DocumentEngine` and `IndexPayload`. Two engines ship: markdown and plain
text.

M1 adds the structure that makes a vault a vault rather than a folder of files:
hierarchy, links between documents, and the operations that keep links correct
when documents move.

M0 deliberately left two hooks for this milestone:

- `IndexPayload.links: [String]` exists on every engine's payload and is
  documented as "Always empty in M0; M1 populates it."
- `DocumentSession.cancelPendingSave()` and `resolveByReloading()` (with its
  `reloadGeneration` counter) exist because M0's final review found that a
  pending autosave could resurrect a deleted file. M1's bulk rewriting depends
  on both.

### Format position, unchanged from M0

Lore-native is the source of truth; markdown is a first-class peer. Wikilinks
live in markdown documents, so their syntax and resolution semantics follow
Obsidian — a link Lore writes must be a link Obsidian resolves, and vice versa.

## Scope decisions

Four decisions were made during design and constrain everything below.

| Decision | Choice | Rejected |
|---|---|---|
| Link syntax | Names, aliases, headings; block refs parsed but not resolved | Full block-reference resolution (M2 owns the renderer) |
| Rename semantics | Preview, then apply, skipping conflicts | Automatic rewrite (Obsidian-style); identity-based non-rewriting |
| Folder UI | Tree, with the flat list retained as a mode | Tree only; breadcrumb navigation |
| Delete | macOS Trash via `trashItem` | Vault-local `.trash/`; a setting offering both |

## Link model

### Parsing

New: `Sources/LoreFeature/Logic/LinkParser.swift`. Extracts links from markdown
body text and returns raw targets.

Handled:

- `[[Note]]`
- `[[Note|display text]]`
- `[[Note#Heading]]`
- `[[Note#^block-id]]` — recorded with the target kept whole, not resolved
- `![[Note]]` — embed, flagged as such
- `[text](relative/path.md)` — markdown links

**Must not match inside fenced code blocks or inline code.** M0's
`MarkdownEngine.outline(of:)` has exactly this gap and it is a recorded deferred
minor; repeating it here would put phantom links in the graph and phantom
entries in backlinks.

`MarkdownEngine.indexPayload.links` is populated from this. `PlainTextEngine`
returns none.

### Resolution

New: `LinkResolver`, owned by `VaultIndexCoordinator`. Resolution is a separate
concern from parsing and must not live in the parser.

Obsidian's rule, which M1 matches: a target resolves against **basename first**,
disambiguating by path only when several documents share a basename. `[[Design]]`
finds `Projects/Design.md` although the link names neither the folder nor the
extension. Frontmatter aliases participate. Matching is case-insensitive, as
Obsidian is on macOS.

Three outcomes, all first-class:

- **resolved** — exactly one match
- **ambiguous** — several matches; resolve to the shortest path (matching
  Obsidian) and record the ambiguity for display
- **unresolved** — no match. A normal state, not an error: it is how a link to
  a not-yet-written note behaves.

### Index schema — version 3

```sql
CREATE TABLE links(
  source_path TEXT,      -- document containing the link
  raw_target  TEXT,      -- exactly as written, e.g. "Note#Heading"
  target_path TEXT,      -- resolved document, NULL if unresolved
  is_embed    INTEGER
);
```

Rebuilt inside the same single write transaction as `documents`. `replaceAll`
already batches; links must never disagree with the documents they were derived
from.

`user_version` moves 2 → 3. Migration is unchanged from M0: version mismatch
deletes the index file and rebuilds from disk, which is safe because the index is
derived state.

**Why `raw_target` is stored alongside `target_path`:** rename rewriting must
reproduce the user's original syntax. A link written `[[design]]` that resolved
to `Projects/Design.md` must be rewritten as `[[new-name]]`, not as
`[[Projects/New Name.md]]`. Storing only the resolution would silently normalize
every link in the vault on the first rename — a bulk mutation nobody requested.

**Backlinks are a query, not a second structure:**
`SELECT source_path FROM links WHERE target_path = ?`. Unresolved-link listing is
the same query with `target_path IS NULL`.

## Rename, move, and trash

### Rename is a previewed transaction

New: `Sources/LoreFeature/Logic/LinkRewriter.swift`.

`LinkRewriter` computes the entire change set before touching anything: the file
move plus every inbound link edit, derived from the `links` table. The UI shows
the count and the affected file list. Nothing is written until the user confirms.

**Application order is fixed: rewrite inbound links first, then move the file.**
Reversed, a crash mid-operation leaves a renamed file with every link in the
vault pointing at nothing. In this order, a crash leaves links pointing at a
not-yet-renamed file — still resolvable, still correct.

**Conflict handling.** Each rewritten file goes through the same mtime check
`DocumentSession` uses. A file that changed on disk since the scan is **skipped
and reported**, never overwritten. With Obsidian open on the same vault, a
rewrite pass that ignores mtime is precisely how an edit made seconds earlier
would be lost.

The operation returns a report: rewritten, skipped, failed. **Partial success is
the expected case, not an error state**, and must be surfaced rather than
swallowed.

### Open tabs

A rewritten file that is open in a tab has a `DocumentSession` holding stale
content, whose next autosave would clobber the rewrite. Therefore:

1. Before any write, every affected session gets `cancelPendingSave()`.
2. After the pass, affected sessions reload via `resolveByReloading()`, which
   bumps `reloadGeneration` so the editor view refreshes rather than showing
   stale text.
3. A tab on the *renamed* document follows it — `session.url` is mutable, from
   M0's save-a-copy adoption work.

### Rename acts on the filename, not the title

A markdown note has two names: its filename and its frontmatter `title:`. **Rename
changes the filename only.** The frontmatter block is not touched, for the same
reason M0's serializer became preserve-and-patch — Lore does not rewrite what the
user did not ask it to change, and a rename request is about the file's identity
in the vault, not about the document's declared title.

Consequence, stated so it is not a surprise: after renaming `design.md` to
`architecture.md`, the sidebar may still show "Design" if that note's frontmatter
says `title: Design`. That is correct. A user who wants both changed edits the
title in the editor, which is a separate, single-file, already-safe operation.

### Move and folder rename

**Move is rename without the name change** — same code path, same preview, same
rewriting. Moving a document changes how ambiguous basenames resolve even when
the name is identical, so it cannot skip the rewrite pass.

**Folder rename** applies the same operation to every document beneath it, under
one combined preview. It is the largest bulk mutation M1 ships.

### Trash

`FileManager.trashItem`. On failure — network volume, external drive with no
`.Trashes` — report and stop. **Never fall back to `removeItem`:** quietly doing
something less safe than the user asked for is its own bug.

Trashing checks inbound links and warns ("3 notes link here") before proceeding,
but does **not** rewrite them. An unresolved link to a deleted note is the
correct outcome and is how the user finds what broke.

### Undo

Explicitly out of scope for M1. This is why the preview is a requirement rather
than a nicety.

## UI

### Sidebar

Splits into a new `FolderTreeView` and the existing `NoteListView` (98 lines,
already handling search and tag chips), with a segmented Tree / All toggle. The
tree is a separate view over the same `store.rows`, grouping by path relative to
the vault root. Expansion state persists in `PluginDocumentStore`.

Search and tag filters force flat rendering in both modes: a filtered tree of
mostly-empty branches is worse than a list.

Folder operations live here — create, rename, move (drag), trash — each routing
to the preview flow for anything that rewrites links. Unclaimed rows (`.pdf`,
`.pages`) appear in their real folders and still carry no Delete item, as M0 left
them.

### Backlinks panel

A collapsible panel at the foot of `DocumentPane`, listing each linking document
with the surrounding line as context. A bare list of filenames is meaningfully
less useful than seeing why something links here. One query per open document,
run on tab switch.

An **Unresolved links** section in the same panel lists this document's outbound
links that resolve to nothing, each offering "Create note" — which is how stub
notes get written in practice.

### Editor affordances

- **Autocomplete:** typing `[[` in `MarkdownEditor` opens a filtered completion
  list over document titles and aliases; selection inserts the shortest
  unambiguous target. Without this, linking is present but unused, because typing
  exact filenames from memory is worse than not linking.
- **Click to open:** resolved targets open in a tab; unresolved targets offer to
  create the note in the default note folder. `MarkdownEditor` is a plain themed
  text view today with no click handling, so this is new work rather than a
  hookup, and is the fiddliest part of the UI.

## Failure modes

Consistent with M0's degrade-never-block rule.

| Condition | Behavior |
|---|---|
| Ambiguous link | Opens the shortest-path match; ambiguity marked in the backlinks panel |
| Link into an unclaimed file type | Opens the M0 fallback viewer |
| Link to a trashed document | Becomes unresolved; offers to create |
| Rewrite target changed on disk | Skipped and reported; never overwritten |
| `trashItem` fails | Reported; no deletion occurs |
| Link parse failure on one document | That document contributes no links; the scan continues |

## Testing

**Parser** — the shapes that actually break link parsers: links inside fenced
code blocks and inline code, nested brackets, pipes inside display text, unicode
filenames, an unclosed `[[`.

**Resolver** — basename collisions across folders, alias resolution,
case-insensitivity, shortest-path tie-breaking, unresolved targets.

**Rewriter** (the critical set):

- a rename whose pass hits a file changed on disk — skipped, reported, and the
  file's content untouched
- a rename with an open dirty tab on a rewritten file — no clobber, session
  reloaded
- a folder rename touching many documents under one preview
- the ordering property: links are rewritten before the file moves
- raw-target fidelity: `[[design]]` rewrites to `[[new-name]]`, not to a
  normalized full path

**Store level** — a `trashItem` failure never deletes; trashing warns on inbound
links without rewriting them.

**Index** — schema 3 migration rebuilds rather than reads a version-2 index;
links and documents are written in one transaction.

## Explicitly out of scope for M1

- Undo for rename/move/trash
- Block-reference (`#^id`) resolution and embed rendering — M2
- Markdown preview, outline navigation, heading scroll targets — M2
- A graph view — M5
- A trash browser or restore UI
- Vault-local `.trash/` as an alternative to system Trash

## Success criteria

1. A wikilink written in Obsidian resolves in Lore, and one written in Lore
   resolves in Obsidian.
2. The backlinks panel lists every document linking to the open one, with
   context, including links written as `[[Note#Heading]]` and `[[Note|alias]]`.
3. Renaming a note previews its inbound link edits and, on confirm, leaves every
   link resolving — with any conflicted file skipped and reported rather than
   overwritten.
4. Renaming a folder applies the same guarantee to every document beneath it.
5. Links inside fenced code blocks never appear in the graph.
6. Deleting a document moves it to the macOS Trash, and a `trashItem` failure
   never results in deletion.
7. A rename whose target file is open in a dirty tab neither loses the tab's
   edits nor leaves the tab showing stale text.
8. All existing tests pass; no source file exceeds 500 lines.
