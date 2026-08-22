import { EditorState, RangeSetBuilder } from "@codemirror/state"
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
  const embeds = embedRanges(state)
  const insideEmbed = (from, to) => embeds.some(r => from < r.to && to > r.from)
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
      if (!MARKER_NODES.has(node.name)) return
      if (revealed.has(line)) return
      if (insideEmbed(node.from, node.to)) return
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

const livePreview = EditorView.decorations.compute(["doc", "selection"],
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
