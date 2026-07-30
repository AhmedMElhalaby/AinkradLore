# Lore M2a — Markdown Core

**Date:** 2026-07-30
**Status:** Design approved, pending spec review
**Milestone:** M2a of the Lore document-workstation roadmap
**Predecessors:** M0 — document-engine architecture (merged, PR #8); M1 — structure and linking (merged, PR #9)

## Context

Lore parses markdown in three separate places, and they disagree:

| Scanner | Basis | Fence-aware |
|---|---|---|
| `LinkParser` | hand-written span scanner | Yes — hardened across three review rounds in M1 |
| `MarkdownStyler` | regex | **No** — styles bold and links inside code blocks |
| `MarkdownEngine.outline` | line scan | **No** — a `#` comment in a code block becomes a heading in the index |

Every feature this milestone wants — rendered styling, outline navigation, task
checkboxes, code blocks — reads markdown structure. A fourth scanner would
guarantee further drift. M2a replaces all three with one parser.

M1 demonstrated the cost of hand-rolled scanning directly: the rewriter was
fence-blind while the parser was fence-aware, so a single real link in a file
caused every `[[link]]` in that file's code blocks to be rewritten. That defect
was found only because a reviewer went looking for it.

### Scope decision

M2 as originally scoped (preview, outline, tasks, highlighting, find/replace,
attachments, folder create/delete, link repair) is comparable in size to M1,
which ran fourteen tasks. It splits along a real seam:

- **M2a — Markdown core** *(this spec)*: parse markdown correctly, once, and
  the three things that read structure — styling, outline, tasks.
- **M2b — Editing tools & vault chores**: find-and-replace, attachments, folder
  create/delete with a recursive-trash store API, and the link-repair pass for
  markdown links an earlier Lore rename wrote with a raw space.

M2b's items barely touch the parser: find/replace works on text ranges,
attachments are file operations, folder ops are store-level, and link repair
reuses M1's existing rewriter behind a preview.

## Decisions

Four decisions were made during design and constrain everything below.

| Decision | Choice | Rejected |
|---|---|---|
| Parser | Adopt `swift-markdown` (CommonMark, SPM product `Markdown`) | Grow one hand-written parser; keep three scanners and patch the fence gaps |
| Reading experience | Deepen in-place styling — no separate preview pane | Split source/rendered view; edit/read mode toggle |
| Code highlighting depth | Monospace, background, language label | Per-token syntax colouring |
| Scope | Markdown core only | Bundling M2b's editing tools |

An edit/read mode toggle remains a reasonable later addition, particularly for
tables, which style poorly in place. It is out of scope here.

## Architecture

### `MarkdownDocumentModel`

The single place the application parses markdown. Holds a parsed `Document` and
derives everything else from it: style spans, outline entries, task items, and
the text regions wikilink extraction is allowed to see.

**Three scanners retire into it:**

- `MarkdownStyler` — deleted. Style spans come from an AST walk.
- `MarkdownEngine.outline` — deleted. Headings come from `Heading` nodes, which
  fixes a bug currently shipping in the index.
- `LinkParser`'s span scanner — its fence and code-region logic is superseded by
  the AST. **Its wikilink grammar and the `DocumentLink` / `LinkSyntax` types
  stay exactly as they are.**

### Wikilinks remain a custom pass

Wikilinks are not CommonMark; `swift-markdown` sees `[[Design]]` as literal
text. Extraction becomes a pass over `Text` nodes only — which is strictly
better than today, because the AST identifies which text is inside code rather
than the scanner re-deriving it.

**Load-bearing constraint:** M1's link layer was hardened across many review
rounds and closed six data-loss paths. The AST changes *how candidate text is
found*. It must not change *what counts as a link* or *what is written back*.
**Every existing `LinkParser` test must pass unchanged.** That is the regression
gate on the parser swap.

### `SourceOffsetMap`

`swift-markdown` reports positions as `SourceRange` — 1-based line and column.
`NSTextView` needs UTF-16 offsets. The conversion is the real work of this
milestone's foundation, and it is where this codebase has been bitten before.

- **CRLF.** Swift treats `"\r\n"` as one `Character` but two UTF-16 code units.
  M1 lost a fix round to `split(separator: "\n")` silently not splitting CRLF
  documents — the parser saw a whole Windows-authored file as one line. A
  naïve line/column table is wrong on every such note, and wrong *silently*.
- **Columns are not UTF-16 columns.** cmark counts bytes; an emoji or accented
  character shifts every subsequent column on that line.
- **Frontmatter.** The parser sees the body; the editor holds the whole file.
  Offsets need the `Frontmatter.bodyOffset` shift M1 already built.

`SourceOffsetMap` is built once per parse and converts a `SourceLocation` to a
UTF-16 offset in the full document. It is a small, pure, ruthlessly testable
type. If it is wrong, every feature above it styles the wrong characters.

## Styling pipeline

`MarkdownDocumentModel.styleSpans` walks the AST once and emits `[StyleSpan]` —
the type `MarkdownEditor.applyStyles` already consumes, so the editor keeps its
interface while its source of truth changes underneath.

Span kinds grow from six to cover what the AST reports reliably: heading level,
emphasis, strong, inline code, code block (with info string), link, wikilink,
list item, block quote, and task checkbox with checked state.

**In-place rendering.** Headings take a size ramp and weight; strong and
emphasis take their traits; inline code and code blocks take a monospace font
and a background; links and wikilinks take the accent colour; block quotes take
a leading indent and a muted foreground. **Syntax markers stay visible** — this
is Live Preview, not WYSIWYG. Hiding `**` in a source editor is where that model
starts fighting the caret.

### Performance

`applyStyles` currently runs a full regex sweep on every keystroke, and an AST
parse is heavier than that.

1. **Debounce the parse, not the styling.** Re-parse on ~150ms idle. Between
   parses, keep the previous spans and shift offsets after the edit point by the
   edit's delta, so typing stays visually stable instead of un-styling and
   re-styling.
2. **Parse once per change, share the result.** Styling, outline, tasks, and
   link extraction all consume one `Document`.
3. **Cap it, explicitly.** Above **256 KB** of body text, styling is restricted
   to the visible range plus a margin, re-derived on scroll; the outline and
   task lists still come from a full parse, which happens once per debounce
   rather than per keystroke. Above **2 MB**, styling is disabled entirely and
   the editor states plainly that the document is too large to style. Both
   thresholds are named constants with the reasoning at the declaration. A note
   that is slow to type in is worse than one that is plainly styled.

### Attribute application

Every re-style clears the styled range before reapplying. With more span kinds,
a stale attribute can otherwise survive an edit — text that stops being bold but
stays bold on screen.

### Interaction with M1's editor

`MarkdownEditor` already owns `[[` autocomplete, Cmd-click-to-open, a
non-key completion panel, and a scroll observer. None of it changes. But
styling now runs on a debounce, so M2a must verify the completion panel's caret
tracking and click-target resolution still behave when styling lags the text by
a frame. That seam is where a regression would hide.

## Outline

Headings are a projection of the AST, not a second scan. Two consumers:

- `IndexPayload.outline` — carried since M0, finally populated correctly.
- A new outline section for the open document: click a heading, scroll to it.
  Entries carry ranges via `SourceOffsetMap`, so scrolling targets a real range
  rather than performing a text search.

This fixes the live bug where a `#` comment inside a fenced code block becomes a
heading in the index.

## Task checkboxes

GFM task list items parse as `ListItem` with a `checkbox` property, so detection
is the AST's job.

**Toggling must go through the normal edit path.** Clicking a checkbox replaces
`- [ ]` with `- [x]` as an ordinary text edit: same undo stack, same dirty flag,
same debounced autosave, same external-change guard. It must not be a special
write that bypasses `DocumentSession` — every guard M0 and M1 built lives on that
path. A toggle is a one-character replacement at a known offset; that is all it
should ever be.

## Code blocks

Fenced blocks carry an info string (` ```swift `). Scope for M2a: monospace
font, background, and a language label. **Not** per-token syntax colouring —
that means either another grammar dependency or hand-written tokenizers per
language, and eliminating hand-rolled scanners is this milestone's premise. True
syntax colouring deserves its own decision later.

## Failure modes

Consistent with the project's degrade-never-block rule.

| Condition | Behavior |
|---|---|
| Parse failure | Previous spans stay in place; styling is not stripped |
| A source location that fails to map to an offset | That span is dropped. A wrong range is worse than no style |
| Malformed task item | Styles, but offers no toggle |
| Document beyond the size cap | Plain or incrementally styled; typing stays responsive |
| Frontmatter present | Offsets shifted by `Frontmatter.bodyOffset`; frontmatter itself is not styled as markdown |

## Testing

**`SourceOffsetMap`** gets the adversarial set: CRLF, CR-only, mixed endings,
multi-byte scalars, emoji, a document with frontmatter, an empty document, and a
document whose final line has no terminator.

**Styling and outline** get golden tests over a document containing every
construct, including the cases that fail today: `#` inside a code fence,
`**bold**` inside a code fence, and `[[link]]` inside a code fence.

**Task toggling** is tested at the store level: toggle produces exactly a
one-character change on disk, the session is dirty, and undo restores it.

**Regression gate:** M1's entire `LinkParser` suite passes unchanged.

## Explicitly out of scope for M2a

- Find-and-replace, attachments, folder create/delete, link repair — all M2b
- Per-token syntax colouring inside code blocks
- A separate rendered preview pane or an edit/read mode toggle
- Table rendering beyond in-place styling
- Block-reference (`#^id`) resolution — still M-later
- Any change to how links are resolved, indexed, or rewritten

## Success criteria

1. Exactly one markdown parser exists in the codebase; `MarkdownStyler` and
   `MarkdownEngine.outline` are deleted.
2. M1's `LinkParser` test suite passes unchanged.
3. A `#` comment, a `**bold**` run, and a `[[link]]` inside a fenced code block
   are all inert: no heading in the index, no styling, no graph entry.
4. Headings, emphasis, strong, code, links, wikilinks, block quotes and lists
   render in place with syntax markers still visible.
5. The outline lists the open document's headings and clicking one scrolls to it.
6. Clicking a task checkbox toggles it through the normal edit path — undoable,
   dirty-flagged, autosaved, and subject to the external-change guard.
7. Offsets are correct for a CRLF document, a document containing emoji, and a
   document with frontmatter.
8. Typing remains responsive at scale, measured rather than asserted: a
   benchmark types into a 256 KB document and shows no per-keystroke full
   parse, with the parse count bounded by the debounce rather than by the
   number of characters typed. The project already has a benchmark harness
   (`LoreRebuildBenchmark`) to follow.
9. All existing tests pass; no source file exceeds 500 lines.
