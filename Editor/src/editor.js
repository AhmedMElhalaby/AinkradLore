import { EditorState, RangeSetBuilder } from "@codemirror/state"
import { EditorView, Decoration, WidgetType, keymap, drawSelection,
         rectangularSelection, highlightActiveLine } from "@codemirror/view"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import { markdown } from "@codemirror/lang-markdown"
import { syntaxHighlighting, HighlightStyle } from "@codemirror/language"
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
        td.textContent = cell
        td.contentEditable = "true"
        td.dataset.r = String(r); td.dataset.c = String(c)
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
        history(), drawSelection(), rectangularSelection(), highlightActiveLine(),
        search(), highlightSelectionMatches(),
        keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap]),
        markdown(), syntaxHighlighting(highlight),
        tablePlugin, EditorView.lineWrapping,
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
