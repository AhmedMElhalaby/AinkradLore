import { EditorState, RangeSetBuilder, StateField, StateEffect } from "@codemirror/state"
import { EditorView, Decoration, WidgetType, keymap, drawSelection,
         rectangularSelection } from "@codemirror/view"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import { markdown } from "@codemirror/lang-markdown"
import { syntaxHighlighting, HighlightStyle, syntaxTree } from "@codemirror/language"
import { searchKeymap, highlightSelectionMatches, search, openSearchPanel } from "@codemirror/search"
import { tags as t } from "@lezer/highlight"

// S3: every colour is a CSS variable, so HostThemeTokens maps in without JS.
const highlight = HighlightStyle.define([
  { tag: t.heading1, fontSize: "1.8em", fontWeight: "600" },
  { tag: t.heading2, fontSize: "1.6em", fontWeight: "600" },
  { tag: t.heading3, fontSize: "1.4em", fontWeight: "600" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: [t.link, t.url], color: "var(--accent-primary)" },
  { tag: t.monospace, fontFamily: "var(--font-mono)" },
  { tag: t.meta, color: "var(--text-faint)" },
])

// ---------------------------------------------------- inline live preview
//
// E2T0. Without this the editor shows `## Heading` and `**bold**` with their
// syntax on screen at all times, which is not Live Preview — it is a source
// editor with colours, and it is what the first screenshot of a real note
// showed.
//
// The rule is Obsidian's and the same one the native renderer already
// implements (`MarkdownReveal`): syntax is hidden unless the CARET IS ON ITS
// LINE, so the marker you need to edit is the one you are standing in. Line
// scope, not block scope — a five-item list must not show all five bullets
// because the caret is in one of them.

/// Marker node types whose text is notation and nothing else.
///
/// Names come from lezer-markdown. `CodeMark` covers both inline backticks and
/// a fence's ```; `HeaderMark` covers the `#` run and a setext underline.
const MARKER_NODES = new Set([
  "HeaderMark", "EmphasisMark", "StrikethroughMark", "CodeMark",
  "QuoteMark", "LinkMark", "CodeInfo",
])

/// A drawn horizontal rule, standing in for `---`.
class RuleWidget extends WidgetType {
  toDOM() {
    const hr = document.createElement("hr")
    hr.className = "cm-lore-rule"
    return hr
  }
  eq() { return true }
  ignoreEvent() { return true }
}

/// The bullet a collapsed list marker is replaced by.
///
/// Depth cycles disc, circle, square — the same decision M9 measured against
/// Obsidian. An ordered item keeps its own number, because a number is already
/// its own distinguishing mark.
class BulletWidget extends WidgetType {
  constructor(text, depth) { super(); this.text = text; this.depth = depth }
  eq(other) { return other.text === this.text && other.depth === this.depth }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-lore-bullet"
    const ordered = /\d/.test(this.text)
    span.textContent = ordered ? this.text.trim()
                               : ["•", "◦", "▪"][this.depth % 3]
    return span
  }
  ignoreEvent() { return true }
}

/// A rendered `[[wikilink]]`.
///
/// E2T1b. Resolution stays in Swift — this widget knows the raw target and
/// nothing else, and a click hands that target over the bridge exactly as the
/// native editor hands it to `onOpenLink`. Keeping vault knowledge on the Swift
/// side is what stops the editor surface from needing its own index.
/// The DOM for a rendered wikilink, wherever it appears.
///
/// Shared by `WikilinkWidget` and by a table cell's `renderInline`, because a
/// link inside a cell that merely LOOKS like a link — or worse, stays as
/// `[[Design Doc]]` while every other link on the page is rendered — is the
/// half-rendered table the first real-note screenshot showed.
function wikilinkSpan(target, display) {
  const a = document.createElement("span")
  a.className = "cm-lore-wikilink"
  a.textContent = display
  a.dataset.target = target
  // `mousedown`, not `click`: CM6 moves the caret on mousedown, and by the time
  // a click lands the selection has already changed — which reveals the line
  // and destroys the very widget being clicked.
  a.addEventListener("mousedown", event => {
    event.preventDefault()
    event.stopPropagation()
    window.webkit?.messageHandlers?.lore?.postMessage({
      kind: "openLink", target, beside: event.metaKey,
    })
  })
  return a
}

/// Split `target|display` — one place, so a cell and a widget cannot disagree
/// about which half is which.
function splitWikilink(inner) {
  const bar = inner.indexOf("|")
  const target = (bar === -1 ? inner : inner.slice(0, bar)).trim()
  const display = bar === -1 ? target : inner.slice(bar + 1).trim()
  return { target, display: display || target }
}

class WikilinkWidget extends WidgetType {
  constructor(target, display) { super(); this.target = target; this.display = display }
  eq(other) { return other.target === this.target && other.display === this.display }
  toDOM() { return wikilinkSpan(this.target, this.display) }
  // The widget handles its own mousedown; CM6 must not also treat it as a
  // click in the text.
  ignoreEvent() { return true }
}

/// The ranges in which `[[…]]` is documentation about a link, not a link.
///
/// The same exclusion `LinkParser` applies on the Swift side, and for the same
/// reason: a `[[Design]]` written inside a fenced block is prose. Rendering it
/// as a link here — while Swift's link graph excludes it — would give the
/// reader something clickable that no backlink, and no rename, knows about.
function codeRanges(state) {
  const ranges = []
  syntaxTree(state).iterate({
    enter: node => {
      if (node.name === "InlineCode" || node.name === "FencedCode" ||
          node.name === "CodeBlock" || node.name === "CodeText") {
        ranges.push({ from: node.from, to: node.to })
      }
    },
  })
  return ranges
}

/// Every `[[target]]` / `[[target|display]]` outside code.
///
/// An `![[embed]]` is deliberately SKIPPED: it is a different construct with a
/// different rendering (E2T1c), and treating it as a plain link here would
/// leave a stray `!` in front of the rendered result.
function wikilinkRanges(state) {
  const text = state.doc.toString()
  const code = codeRanges(state)
  const inCode = (from, to) => code.some(r => from < r.to && to > r.from)
  const found = []
  const pattern = /\[\[([^\[\]\n]+)\]\]/g
  let match
  while ((match = pattern.exec(text)) !== null) {
    const from = match.index
    if (from > 0 && text[from - 1] === "!") continue
    const to = from + match[0].length
    if (inCode(from, to)) continue
    const { target, display } = splitWikilink(match[1])
    if (!target) continue
    found.push({ from, to, target, display })
  }
  return found
}

/// Where `![[…]]` sits — the ranges in which NO marker may be hidden yet.
///
/// Found by the screenshot, not by a test. lezer parses `![[x]]` as an image,
/// so its `!` and brackets are `LinkMark` nodes and E2T0's marker-hiding
/// collapsed the whole thing to a bare `x` styled as a link. An embed that
/// renders as a link to a file is worse than an embed that renders as its own
/// source: the reader is shown a construct that does not exist. Until E2T1c
/// renders embeds properly, their syntax stays on screen — visibly unfinished
/// rather than quietly wrong.
///
/// The earlier test asserted `wikilinkTargets() === []` for an embed, which was
/// true and proved nothing: the rendering came from a different code path.
function embedRanges(state) {
  const text = state.doc.toString()
  const code = codeRanges(state)
  const found = []
  const pattern = /!\[\[([^\[\]\n]+)\]\]/g
  let match
  while ((match = pattern.exec(text)) !== null) {
    const from = match.index, to = from + match[0].length
    if (code.some(r => from < r.to && to > r.from)) continue
    found.push({ from, to })
  }
  return found
}

/// Ranges in which a `#` is part of a LINK, not a tag.
///
/// `[text](https://x.test/page#anchor)` and `[[Target#Heading]]` both contain a
/// `#` that means something else. The native scanner excludes both, from two
/// different sources for the same reason lezer gives here: `[[…]]` is not
/// CommonMark, so the tree knows nothing about it.
function linkRanges(state) {
  const ranges = []
  syntaxTree(state).iterate({
    enter: node => {
      if (node.name === "Link" || node.name === "Image" || node.name === "URL") {
        ranges.push({ from: node.from, to: node.to })
      }
    },
  })
  for (const w of wikilinkRanges(state)) ranges.push({ from: w.from, to: w.to })
  for (const e of embedRanges(state)) ranges.push({ from: e.from, to: e.to })
  return ranges
}

/// `#tag`, `#nested/tag`.
///
/// A deliberate transcription of `MarkdownExtensions.scanTags`, disqualification
/// for disqualification, because the tags this surface shows must be exactly the
/// tags the index holds — a tag rendered here that the sidebar does not list is
/// a tag the reader cannot click through to anything.
///
/// The `#` STAYS in the span. Obsidian keeps it, and a chip without it is
/// indistinguishable from a link chip.
function tagRanges(state) {
  const text = state.doc.toString()
  const excluded = codeRanges(state).concat(linkRanges(state))
  const isExcluded = at => excluded.some(r => at >= r.from && at < r.to)
  const found = []
  let i = 0
  while (i < text.length) {
    if (text[i] !== "#" || isExcluded(i)) { i++; continue }
    // A heading: `#`(s) at line start, then a space. The AST owns it.
    const atLineStart = i === 0 || text[i - 1] === "\n"
    if (atLineStart) {
      let h = i
      while (h < text.length && text[h] === "#") h++
      if (text[h] === " ") { i = h; continue }
    }
    let j = i + 1
    let hasNonDigit = false
    while (j < text.length) {
      const ch = text[j]
      const code = text.charCodeAt(j)
      const isDigit = ch >= "0" && ch <= "9"
      const isLetter = /[A-Za-z]/.test(ch) || code > 0x7f
      const isJoiner = ch === "_" || ch === "-" || ch === "/"
      if (!(isDigit || isLetter || isJoiner)) break
      if (isLetter || isJoiner) hasNonDigit = true
      j++
    }
    const name = text.slice(i + 1, j)
    // At least one non-digit, or `#1234` — an issue reference — becomes a tag
    // and every changelog in the vault fills with them.
    if (!hasNonDigit || !name) { i++; continue }
    // A trailing `/` is notation the author is mid-typing. It is trimmed from
    // the NAME but stays inside the span, so the chip does not visibly clip
    // under the caret.
    const trimmed = name.endsWith("/") ? name.slice(0, -1) : name
    if (!trimmed) { i++; continue }
    found.push({ from: i, to: j, name: trimmed })
    i = j
  }
  return found
}

/// A tag chip. Clicking it filters the vault, exactly as the sidebar's chip
/// row does — the same `onTagClick` the native editor is handed.
class TagWidget extends WidgetType {
  constructor(text, name) { super(); this.text = text; this.name = name }
  eq(other) { return other.text === this.text && other.name === this.name }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-lore-tag"
    span.textContent = this.text
    span.dataset.tag = this.name
    span.addEventListener("mousedown", event => {
      event.preventDefault()
      event.stopPropagation()
      window.webkit?.messageHandlers?.lore?.postMessage(
        { kind: "openTag", tag: this.name })
    })
    return span
  }
  ignoreEvent() { return true }
}

// ------------------------------------------------------- editor settings
//
// These two are STATE, not module variables.
//
// They were module-level `let`s with a `view.dispatch({})` to redraw, and that
// silently did nothing: the decoration facet is computed from `["doc",
// "selection"]`, an empty transaction changes neither, so CM6 correctly reused
// its cached decorations. Turning chips off left every chip on screen. Putting
// the settings in a StateField and naming that field as a dependency is what
// makes "redraw when this changes" true rather than intended.

/// `{ tagsAsChips, tasksToggleable }`.
const settingsEffect = StateEffect.define()

const settingsField = StateField.define({
  create: () => ({ tagsAsChips: true, tasksToggleable: true }),
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(settingsEffect)) return { ...value, ...effect.value }
    }
    return value
  },
})

/// A task checkbox that can actually be clicked.
///
/// E2T4, and the clearest single case for this whole milestone: the native
/// editor draws a checkbox and routes a click back through
/// `MarkdownEditorClicks` to edit the text underneath a picture. Here the
/// checkbox IS an input, and toggling it dispatches a one-character change to
/// the document — no drawn stand-in, no hit-testing against a painted rect.
class CheckboxWidget extends WidgetType {
  constructor(checked, from, toggleable) {
    super(); this.checked = checked; this.from = from; this.toggleable = toggleable
  }
  // `toggleable` is part of identity: without it, turning the session
  // read-only leaves every already-drawn checkbox enabled, because CM6 keeps a
  // widget whose `eq` says nothing changed.
  eq(other) {
    return other.checked === this.checked && other.from === this.from &&
           other.toggleable === this.toggleable
  }
  toDOM(view) {
    const box = document.createElement("input")
    box.type = "checkbox"
    box.className = "cm-lore-checkbox"
    box.checked = this.checked
    // A read-only session can never persist this, so it must not offer to —
    // the same reasoning as the native `allowsTaskToggle`.
    box.disabled = !this.toggleable
    box.addEventListener("mousedown", event => {
      // The caret must not move to this line: that would reveal the source and
      // replace the box mid-click.
      event.preventDefault()
      event.stopPropagation()
      if (!this.toggleable) return
      // One character. `[ ]` -> `[x]` is a single-unit change, which keeps the
      // undo grain at "toggled one task" and leaves every other offset in the
      // document exactly where it was.
      view.dispatch({ changes: { from: this.from + 1, to: this.from + 2,
                                 insert: this.checked ? " " : "x" } })
    })
    return box
  }
  ignoreEvent() { return true }
}

/// `- [ ] thing` / `* [x] done`, with the marker's own range.
///
/// Scanned by line rather than taken from the tree: `markdown()` here is
/// CommonMark, which has no task-list node — the same reason the tables in this
/// file are hand-rolled.
function taskLines(state) {
  const found = []
  const doc = state.doc
  for (let n = 1; n <= doc.lines; n++) {
    const line = doc.line(n)
    const match = /^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]($|\s)/.exec(line.text)
    if (!match) continue
    const from = line.from + match[1].length
    found.push({ from, to: from + 3, checked: match[2] !== " ", line: n })
  }
  return found
}

// ------------------------------------------------------------- callouts
//
// E2T3. `> [!note] An optional title` — a block quote whose first line opens
// with `[!type]`. Not CommonMark, so lezer gives us the quote and this gives us
// what the quote MEANS, exactly as `MarkdownCallout` does on the Swift side.

/// Every spelling Obsidian accepts, mapped to a kind. Transcribed from
/// `MarkdownCallout.Kind.named` — a vault written against Obsidian contains
/// `[!tldr]` and `[!caution]` interchangeably with `[!abstract]` and
/// `[!warning]`, and an unrecognised type must fall back to a plain quote
/// rather than render as stray punctuation.
const CALLOUT_ALIASES = {
  note: "note",
  abstract: "abstract", summary: "abstract", tldr: "abstract",
  info: "info",
  todo: "todo",
  tip: "tip", hint: "tip", important: "tip",
  success: "success", check: "success", done: "success",
  question: "question", help: "question", faq: "question",
  warning: "warning", caution: "warning", attention: "warning",
  failure: "failure", fail: "failure", missing: "failure",
  danger: "danger", error: "danger",
  bug: "bug",
  example: "example",
  quote: "quote", cite: "quote",
}

/// What Obsidian shows when the author gave no title.
///
/// DRAWN, never inserted: putting it in the text would change the document and
/// every offset the index and the link graph hold with it.
const CALLOUT_TITLES = {
  note: "Note", abstract: "Abstract", info: "Info", todo: "Todo", tip: "Tip",
  success: "Success", question: "Question", warning: "Warning",
  failure: "Failure", danger: "Danger", bug: "Bug", example: "Example",
  quote: "Quote",
}

/// The glyph beside the title.
///
/// Unicode, not SF Symbols: those are an AppKit facility and this surface is a
/// web view, so the native renderer's `pencil`/`flame`/`ant` cannot be reached
/// from here. Bundling an icon font or inlining thirteen SVG paths buys a
/// closer match than the parity gap justifies, so these are chosen to read as
/// the same SIGNAL — a warning triangle is a warning triangle.
const CALLOUT_ICONS = {
  note: "\u270E", abstract: "\u2261", info: "\u24D8", todo: "\u2611",
  tip: "\u25C6", success: "\u2713", question: "?", warning: "\u26A0",
  failure: "\u2715", danger: "\u26A1", bug: "\u2691", example: "\u2263",
  quote: "\u275D",
}

/// The header a callout's opening line declares, or null for a plain quote.
function calloutHeader(text) {
  const match = /^(\s*>\s*)(\[!([A-Za-z]+)\]([+-]?))(\s*)(.*)$/.exec(text)
  if (!match) return null
  const kind = CALLOUT_ALIASES[match[3].toLowerCase()]
  if (!kind) return null
  return {
    kind,
    markerStart: match[1].length,
    markerEnd: match[1].length + match[2].length,
    // The author's own title is real document text and stays as text; only
    // the `[!type]` notation is replaced.
    title: match[6].trim(),
  }
}

/// The icon, and — when the author wrote no title of their own — the default
/// one, standing in for the `[!type]` notation.
class CalloutMarkerWidget extends WidgetType {
  constructor(kind, needsTitle) { super(); this.kind = kind; this.needsTitle = needsTitle }
  eq(other) { return other.kind === this.kind && other.needsTitle === this.needsTitle }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-lore-callout-marker"
    const icon = document.createElement("span")
    icon.className = "cm-lore-callout-icon"
    icon.textContent = CALLOUT_ICONS[this.kind]
    span.appendChild(icon)
    if (this.needsTitle) {
      const title = document.createElement("span")
      title.className = "cm-lore-callout-default-title"
      title.textContent = CALLOUT_TITLES[this.kind]
      span.appendChild(title)
    }
    return span
  }
  ignoreEvent() { return true }
}

/// Every callout in the document, as line spans.
///
/// A callout runs from its `> [!type]` line for as long as the quote does —
/// consecutive lines beginning with `>`. Found by line scan for the same reason
/// the header is: the construct is not in the tree.
function calloutBlocks(state) {
  const doc = state.doc
  const blocks = []
  let n = 1
  while (n <= doc.lines) {
    const header = calloutHeader(doc.line(n).text)
    if (!header) { n++; continue }
    let last = n
    while (last + 1 <= doc.lines && /^\s*>/.test(doc.line(last + 1).text)) last++
    blocks.push({ first: n, last, header })
    n = last + 1
  }
  return blocks
}

function livePreviewDecorations(state) {
  const builder = new RangeSetBuilder()
  const doc = state.doc
  // The lines the caret (or selection) touches. Their syntax stays visible.
  const revealed = new Set()
  for (const range of state.selection.ranges) {
    const from = doc.lineAt(range.from).number
    const to = doc.lineAt(range.to).number
    for (let n = from; n <= to; n++) revealed.add(n)
  }

  const hidden = []
  const lineClasses = []

  // RESERVED RANGES — the ranges this file replaces with a widget of its own.
  //
  // Every one of them also contains lezer marker nodes: `[x]` and `[!note]`
  // both look like the start of a link, so `LinkMark` covers their brackets.
  // The builder's overlap guard takes whichever decoration comes FIRST at a
  // position and drops the rest, so the bracket-hiding won and the widget was
  // silently discarded — a checked task rendered as a bare `x`, and a callout
  // header as `!note`. Found in a screenshot; nothing in the tests could see
  // it, because each construct's own scanner was working perfectly.
  //
  // So: collect the ranges first, and suppress lezer's markers inside them.
  const settings = state.field(settingsField)
  const tasks = taskLines(state)
  const callouts = calloutBlocks(state)
  const embeds = embedRanges(state)
  const tags = settings.tagsAsChips ? tagRanges(state) : []
  const reserved = embeds.slice()
  for (const t of tasks) reserved.push({ from: t.from, to: t.to })
  for (const tag of tags) reserved.push({ from: tag.from, to: tag.to })
  for (const c of callouts) {
    const line = doc.line(c.first)
    reserved.push({ from: line.from + c.header.markerStart,
                    to: line.from + c.header.markerEnd })
  }
  for (const w of wikilinkRanges(state)) reserved.push({ from: w.from, to: w.to })
  const isReserved = (from, to) => reserved.some(r => from < r.to && to > r.from)
  const taskLineNumbers = new Set(tasks.map(t => t.line))
  syntaxTree(state).iterate({
    enter: node => {
      const line = doc.lineAt(node.from).number
      if (node.name === "HorizontalRule") {
        if (!revealed.has(line)) {
          hidden.push({ from: node.from, to: node.to,
                        deco: Decoration.replace({ widget: new RuleWidget() }) })
        }
        return
      }
      if (node.name === "FencedCode" || node.name === "CodeBlock") {
        // A panel behind the whole fence. Marked as LINE decorations rather
        // than one range: a `Decoration.mark` over a multi-line span paints a
        // ragged staircase — the same reason the native renderer draws a panel
        // instead of using a per-glyph background.
        const first = doc.lineAt(node.from).number
        const last = doc.lineAt(node.to).number
        for (let n = first; n <= last; n++) {
          const line = doc.line(n)
          lineClasses.push({ from: line.from, cls: n === first ? "cm-lore-code-first"
                                                : n === last ? "cm-lore-code-last"
                                                : "cm-lore-code" })
        }
        return
      }
      if (node.name === "ListMark") {
        if (revealed.has(line)) return
        // A task item shows its checkbox, not a bullet AND a checkbox.
        if (taskLineNumbers.has(line)) {
          hidden.push({ from: node.from, to: node.to, deco: Decoration.replace({}) })
          return
        }
        const text = doc.sliceString(node.from, node.to)
        // Indentation before the marker is the nesting depth. Four spaces or a
        // tab per level, which is what the markdown itself uses.
        const before = doc.sliceString(doc.lineAt(node.from).from, node.from)
        const depth = Math.floor(before.replace(/\t/g, "    ").length / 4)
        hidden.push({ from: node.from, to: node.to,
                      deco: Decoration.replace({
                        widget: new BulletWidget(text, depth) }) })
        return
      }
      // A markdown link's target is notation too. Without this, `[a
      // link](https://x.test/p)` renders as `a linkhttps://x.test/p` — the
      // brackets hidden and the URL left sitting against the label, which the
      // screenshot showed and which no marker rule would ever have caught,
      // because `URL` is content as far as lezer is concerned.
      //
      // Only a PARENTHESISED target: an autolink's URL is the visible text,
      // and hiding it would leave the reader nothing at all.
      if (node.name === "URL") {
        if (revealed.has(line)) return
        if (doc.sliceString(Math.max(0, node.from - 1), node.from) !== "(") return
        hidden.push({ from: node.from, to: node.to, deco: Decoration.replace({}) })
        return
      }
      if (!MARKER_NODES.has(node.name)) return
      if (revealed.has(line)) return
      if (isReserved(node.from, node.to)) return
      hidden.push({ from: node.from, to: node.to, deco: Decoration.replace({}) })
    },
  })

  // Wikilinks go through the SAME builder as every other replacement so that
  // one overlap guard covers them all. A `[[link]]` sits inside a LinkMark run
  // as far as lezer is concerned, and two facets each replacing part of that
  // run is how CM6 is made to throw.
  for (const link of wikilinkRanges(state)) {
    if (revealed.has(doc.lineAt(link.from).number)) continue
    hidden.push({ from: link.from, to: link.to,
                  deco: Decoration.replace({
                    widget: new WikilinkWidget(link.target, link.display) }) })
  }

  // Callouts: a tinted panel per line, plus the header's notation replaced by
  // an icon and, when the author wrote none, the default title.
  for (const block of callouts) {
    for (let n = block.first; n <= block.last; n++) {
      const cls = ["cm-lore-callout", "cm-lore-callout-" + block.header.kind,
                   n === block.first ? "cm-lore-callout-head" : "cm-lore-callout-body",
                   n === block.last ? "cm-lore-callout-last" : ""].join(" ").trim()
      lineClasses.push({ from: doc.line(n).from, cls })
    }
    if (revealed.has(block.first)) continue
    const line = doc.line(block.first)
    hidden.push({
      from: line.from + block.header.markerStart,
      to: line.from + block.header.markerEnd,
      deco: Decoration.replace({
        widget: new CalloutMarkerWidget(block.header.kind, !block.header.title) }),
    })
  }

  // Task checkboxes, and the strike-through on a completed one. The line
  // class goes on whether or not the caret is present: a done task reads as
  // done in Obsidian even while you are editing it.
  for (const task of tasks) {
    if (task.checked) lineClasses.push({ from: doc.line(task.line).from,
                                         cls: "cm-lore-task-done" })
    if (revealed.has(task.line)) continue
    hidden.push({ from: task.from, to: task.to,
                  deco: Decoration.replace({
                    widget: new CheckboxWidget(task.checked, task.from,
                                               settings.tasksToggleable) }) })
  }

  // Tags. Replaced rather than MARKED because the chip needs its own click
  // target and its own box; a `Decoration.mark` would give the pill a ragged
  // edge wherever it wrapped.
  if (settings.tagsAsChips) {
    for (const tag of tags) {
      if (revealed.has(doc.lineAt(tag.from).number)) continue
      hidden.push({ from: tag.from, to: tag.to,
                    deco: Decoration.replace({
                      widget: new TagWidget(doc.sliceString(tag.from, tag.to),
                                            tag.name) }) })
    }
  }

  // RangeSetBuilder demands ascending order and the tree walk does not
  // guarantee it across node kinds.
  // Line decorations must be added in document order along with the rest, and
  // RangeSetBuilder takes everything at a position together — so they are
  // merged into one sorted stream rather than added in a second pass.
  for (const l of lineClasses) {
    hidden.push({ from: l.from, to: l.from, line: l.cls })
  }
  hidden.sort((a, b) => a.from - b.from || a.to - b.to)
  let lastTo = -1
  for (const h of hidden) {
    // Overlapping replacements throw. A `CodeMark` inside a `HeaderMark`'s line
    // is legal markdown and would otherwise take the editor down.
    if (h.line) {
      builder.add(h.from, h.from, Decoration.line({ class: h.line }))
      continue
    }
    if (h.from < lastTo) continue
    builder.add(h.from, h.to, h.deco)
    lastTo = h.to
  }
  return builder.finish()
}

const livePreview = EditorView.decorations.compute(
  ["doc", "selection", settingsField],
  state => livePreviewDecorations(state))

/// Render a cell's inline markdown into `parent`.
///
/// E2T1a. The cell used to be set with `textContent`, so `**Web**` appeared
/// with its asterisks INSIDE a rendered table — visible in the first real-note
/// screenshot, and wrong in a way that reads as the table being half-rendered.
///
/// A deliberate SUBSET: bold, italic, inline code. Not a markdown parser — a
/// cell is one line of inline content, and the alternative (running CodeMirror
/// inside a widget inside CodeMirror) is not something to reach for to make
/// three delimiters work. Anything unrecognised is left as literal text, which
/// is the honest failure: the reader sees what they typed.
///
/// Nested emphasis (`**a *b* c**`) renders the outer level only. Recorded
/// rather than hidden; it is rare in a table cell and the fix is a real parser.
function renderInline(text, parent) {
  // `[[…]]` is first in the alternation so a link is never mistaken for
  // emphasis. Its own brackets contain no `*` or `_`, but a DISPLAY half may.
  const pattern = /(\[\[[^\[\]\n]+\]\]|\*\*[^*]+\*\*|__[^_]+__|\*[^*]+\*|_[^_]+_|`[^`]+`)/g
  let index = 0
  let match
  while ((match = pattern.exec(text)) !== null) {
    if (match.index > index) {
      parent.appendChild(document.createTextNode(text.slice(index, match.index)))
    }
    const token = match[0]
    let node
    if (token.startsWith("[[")) {
      const { target, display } = splitWikilink(token.slice(2, -2))
      node = wikilinkSpan(target, display)
    } else if (token.startsWith("**") || token.startsWith("__")) {
      node = document.createElement("strong")
      node.textContent = token.slice(2, -2)
    } else if (token.startsWith("`")) {
      node = document.createElement("code")
      node.textContent = token.slice(1, -1)
    } else {
      node = document.createElement("em")
      node.textContent = token.slice(1, -1)
    }
    parent.appendChild(node)
    index = pattern.lastIndex
  }
  if (index < text.length) {
    parent.appendChild(document.createTextNode(text.slice(index)))
  }
}

// S2, the question this spike exists for. A table's source range is REPLACED
// by a real <table> with contenteditable cells. Typing dispatches a change to
// the underlying document range; the grid never reverts to `| a | b |`, which
// is exactly what a painted grid cannot do.
class TableWidget extends WidgetType {
  constructor(rows, from, cellRanges) {
    super(); this.rows = rows; this.from = from; this.cellRanges = cellRanges
  }
  eq(other) {
    return other.from === this.from &&
           JSON.stringify(other.rows) === JSON.stringify(this.rows)
  }
  toDOM(view) {
    const table = document.createElement("table")
    table.className = "cm-lore-table"
    this.rows.forEach((row, r) => {
      const tr = document.createElement("tr")
      row.forEach((cell, c) => {
        const td = document.createElement(r === 0 ? "th" : "td")
        renderInline(cell, td)
        td.contentEditable = "true"
        td.dataset.r = String(r); td.dataset.c = String(c)
        // `input` rather than `beforeinput`: the cell's text is read AFTER
        // the browser has applied the edit, so `textContent` is what the user
        // now sees. Reading it before would write the previous value.
        td.addEventListener("input", () => {
          const range = this.cellRanges[r] && this.cellRanges[r][c]
          if (!range) return
          view.dispatch({ changes: { from: range.from, to: range.to,
                                     insert: " " + td.textContent.trim() + " " } })
        })
        tr.appendChild(td)
      })
      table.appendChild(tr)
    })
    return table
  }
  ignoreEvent() { return true }
}

function parsePipeRow(line) {
  const cells = [], ranges = []
  let start = null, buf = ""
  for (let i = 0; i < line.text.length; i++) {
    const ch = line.text[i]
    if (ch === "|" && (i === 0 || line.text[i - 1] !== "\\")) {
      if (start !== null) {
        cells.push(buf.trim())
        ranges.push({ from: line.from + start, to: line.from + i })
      }
      start = i + 1; buf = ""
    } else if (start !== null) { buf += ch }
  }
  return { cells, ranges }
}

const isDelimiterLine = text =>
  /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/.test(text)

function buildDecorations(state) {
  const builder = new RangeSetBuilder()
  const doc = state.doc
  let line = 1
  while (line <= doc.lines) {
    const l = doc.line(line)
    if (l.text.includes("|") && line + 1 <= doc.lines &&
        isDelimiterLine(doc.line(line + 1).text)) {
      let last = line + 1
      while (last + 1 <= doc.lines && doc.line(last + 1).text.includes("|")) last++
      const rows = [], cellRanges = []
      for (let r = line; r <= last; r++) {
        if (r === line + 1) continue
        const parsed = parsePipeRow(doc.line(r))
        rows.push(parsed.cells); cellRanges.push(parsed.ranges)
      }
      if (rows.length) {
        builder.add(l.from, doc.line(last).to, Decoration.replace({
          widget: new TableWidget(rows, l.from, cellRanges), block: true,
        }))
        line = last + 1
        continue
      }
    }
    line++
  }
  return builder.finish()
}

const tablePlugin = EditorView.decorations.compute(["doc", "selection"],
                                                   state => buildDecorations(state))

let view = null

// Is a change arriving FROM Swift right now?
//
// The edit loop this guards is the classic one: Swift pushes a document, CM6
// reports it as a change, Swift treats that as user input and pushes again.
// Under a fast typist the two chase each other and keystrokes are dropped —
// silently, and only under load, which is the worst way to find out. So a
// change Swift asked for is never reported back to Swift.
let applyingFromSwift = false

window.loreEditor = {
  init(text) {
    const state = EditorState.create({
      doc: text,
      extensions: [
        history(), drawSelection(), rectangularSelection(),
        // `highlightActiveLine()` is deliberately ABSENT. It paints a
        // full-width grey band behind the caret's line, which Obsidian does
        // not do and which the first wikilink screenshot showed as the loudest
        // thing on the page — a bar wider than the text measure, drawn under
        // the one line the reader is already looking at.

        search(), highlightSelectionMatches(),
        keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap]),
        settingsField,
        markdown(), syntaxHighlighting(highlight),
        livePreview, tablePlugin, EditorView.lineWrapping,
        // CM6 turns the browser's own spellchecking OFF by default. On macOS
        // that also means NSSpellChecker never inspects the text, so a
        // misspelling is never underlined — S7b measured `spellcheck=false`.
        // Opting back in is what hands the surface to the system.
        EditorView.contentAttributes.of({ spellcheck: "true",
                                          autocorrect: "on",
                                          autocapitalize: "off" }),
        EditorView.updateListener.of(u => {
          if (!u.docChanged || applyingFromSwift) return
          window.webkit?.messageHandlers?.lore?.postMessage(
            { kind: "doc", text: u.state.doc.toString() })
        }),
      ],
    })
    view = new EditorView({ state, parent: document.getElementById("root") })
    return view.state.doc.length
  },
  text() { return view.state.doc.toString() },

  /// Test hooks. `insertAtEnd` is what a keystroke amounts to, and
  /// `__setDocumentCalls` counts pushes that actually reached the editor —
  /// which is how the "Swift must not echo" rule is asserted rather than
  /// assumed.
  /// Put the caret at an offset — how a test says "the reader clicked here".
  selectAt(offset) {
    if (offset < 0) return false
    view.dispatch({ selection: { anchor: Math.min(offset, view.state.doc.length) } })
    return true
  },
  insertAtEnd(ch) {
    view.dispatch({ changes: { from: view.state.doc.length, insert: ch } })
    return view.state.doc.length
  },
  __setDocumentCalls: 0,

  /// Replace the whole document because SWIFT says so — a note being opened,
  /// or an external change on disk.
  ///
  /// Returns false and does nothing when the text already matches, so an
  /// echo costs no transaction and, more importantly, cannot move the caret.
  setDocument(text) {
    if (!view) return false
    if (view.state.doc.toString() === text) return false
    window.loreEditor.__setDocumentCalls++
    applyingFromSwift = true
    try {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
        // The caret is clamped rather than preserved at its offset: the new
        // document is a DIFFERENT document, so an offset from the old one
        // means nothing in it.
        selection: { anchor: Math.min(view.state.selection.main.anchor, text.length) },
      })
    } finally {
      applyingFromSwift = false
    }
    return true
  },

  lines() { return view.state.doc.lines },

  /// `EditorSettings.renderTagsAsChips`. Redraws, because a setting that
  /// only takes effect on the next document is a setting that looks broken.
  setTagsAsChips(on) {
    if (!view) return false
    view.dispatch({ effects: settingsEffect.of({ tagsAsChips: !!on }) })
    return view.state.field(settingsField).tagsAsChips
  },
  /// `EditorContext.isReadOnly`, inverted, pushed from Swift.
  setTasksToggleable(on) {
    if (!view) return false
    view.dispatch({ effects: settingsEffect.of({ tasksToggleable: !!on }) })
    return view.state.field(settingsField).tasksToggleable
  },
  checkboxStates() {
    return Array.from(document.querySelectorAll(".cm-lore-checkbox"))
                .map(n => n.checked)
  },
  checkboxDisabled() {
    return Array.from(document.querySelectorAll(".cm-lore-checkbox"))
                .map(n => n.disabled)
  },
  clickCheckbox(index) {
    const node = document.querySelectorAll(".cm-lore-checkbox")[index || 0]
    if (!node) return false
    node.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }))
    return true
  },
  doneLineCount() { return document.querySelectorAll(".cm-lore-task-done").length },
  calloutKinds() {
    return Array.from(document.querySelectorAll(".cm-lore-callout-head"))
                .map(n => (/cm-lore-callout-([a-z]+)/.exec(
                  Array.from(n.classList).find(c =>
                    c.startsWith("cm-lore-callout-") &&
                    !["cm-lore-callout-head", "cm-lore-callout-body",
                      "cm-lore-callout-last"].includes(c)) || "") || [])[1])
  },
  calloutTitles() {
    return Array.from(document.querySelectorAll(".cm-lore-callout-head"))
                .map(n => n.innerText.trim())
  },
  calloutLineCount() { return document.querySelectorAll(".cm-lore-callout").length },
  tagNames() {
    return Array.from(document.querySelectorAll(".cm-lore-tag"))
                .map(n => n.dataset.tag)
  },
  tagTexts() {
    return Array.from(document.querySelectorAll(".cm-lore-tag"))
                .map(n => n.textContent)
  },
  clickTag(index) {
    const node = document.querySelectorAll(".cm-lore-tag")[index || 0]
    if (!node) return false
    node.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }))
    return true
  },

  /// E2T1b hooks. `wikilinkTargets` is what a test asserts the RENDERING
  /// against; `clickWikilink` is what asserts the bridge message, because a
  /// link that renders and does not open is the more likely of the two bugs.
  wikilinkTexts() {
    return Array.from(document.querySelectorAll(".cm-lore-wikilink"))
                .map(n => n.textContent)
  },
  wikilinkTargets() {
    return Array.from(document.querySelectorAll(".cm-lore-wikilink"))
                .map(n => n.dataset.target)
  },
  clickWikilink(index, meta) {
    const nodes = document.querySelectorAll(".cm-lore-wikilink")
    const node = nodes[index || 0]
    if (!node) return false
    node.dispatchEvent(new MouseEvent("mousedown",
                                      { bubbles: true, metaKey: !!meta }))
    return true
  },
  tableCount() { return document.querySelectorAll(".cm-lore-table").length },
  focusFirstCell() {
    const cell = document.querySelector(".cm-lore-table td")
    if (!cell) return false
    cell.focus()
    return document.activeElement === cell
  },
  typeInFirstCell(s) {
    const cell = document.querySelector(".cm-lore-table td")
    if (!cell) return false
    cell.textContent = s
    cell.dispatchEvent(new Event("input", { bubbles: true }))
    return true
  },
  // S4: one character at a time, timed end to end — the same shape as the
  // native MarkdownTypingLagBenchmark.
  openFind() { openSearchPanel(view); return true },
  countMatches(needle) {
    const doc = view.state.doc.toString()
    let n = 0, i = 0
    while ((i = doc.indexOf(needle, i)) !== -1) { n++; i += needle.length }
    return n
  },
  focusEnd() {
    view.focus()
    view.dispatch({ selection: { anchor: view.state.doc.length } })
    return true
  },
  benchTyping(n) {
    const pos = Math.floor(view.state.doc.length / 2)
    const t0 = performance.now()
    for (let i = 0; i < n; i++) view.dispatch({ changes: { from: pos + i, insert: "x" } })
    return (performance.now() - t0) / n
  },
}
