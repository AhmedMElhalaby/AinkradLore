import AppKit
import AinkradAppKit

/// Hosts the editor's own context menu in place of `NSTextView`'s.
///
/// The menu is presented by `.ainkradContextMenu(_:)` (see
/// `AinkradContextMenu.swift` in AinkradAppKitUI), which is a SwiftUI view
/// modifier: its right-click catcher sits in an overlay ABOVE whatever it
/// decorates and owns the event outright, and it draws the panel itself —
/// there is no public hook that hands this module the click before the panel
/// is built. So the items it presents cannot be computed from the exact pixel
/// of a right-click; they are kept current instead, via `onSelectionChange`,
/// from wherever the caret already is. In the ordinary flow — type a word,
/// then right-click it — the caret is already sitting where the click lands,
/// which is the case this task's Dev Host walkthrough exercises. Right-clicking
/// a DIFFERENT word than the caret's, without selecting it first, is a known
/// gap: this suggests against the word at the caret, not the word under the
/// pointer. `AinkradFloatingPanelController`, which actually owns the pixel,
/// is `internal` to AinkradAppKitUI and out of reach from here — and
/// `AinkradAppKit/` is not this task's to change.
extension LinkTextView {
    /// Returning nil suppresses AppKit's own menu entirely. Without this both
    /// menus race and the native one usually wins. Spellchecking ITSELF is
    /// untouched — only its menu is gone; `EditorSpellCheck` below rebuilds
    /// the suggestions through the same `NSSpellChecker` the native menu used.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// Suggestions for the word at a UTF-16 offset, via the shared checker.
enum EditorSpellCheck {

    /// `checkSpelling(of:startingAt:)` and `guesses(forWordRange:in:...)` both
    /// take the WORD as its own string, not the document, so the range each
    /// one wants is relative to that isolated word — `0..<word.length` — not
    /// to the document offset `WordAtPoint` found it at.
    static func suggestions(at offset: Int, in text: String) -> (NSRange, [String])? {
        guard let range = WordAtPoint.range(in: text, atUTF16: offset) else { return nil }
        let word = (text as NSString).substring(with: range)
        let checker = NSSpellChecker.shared
        let misspelled = checker.checkSpelling(of: word, startingAt: 0)
        guard misspelled.location != NSNotFound else { return (range, []) }
        let guesses = checker.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length),
                                      in: word, language: nil,
                                      inSpellDocumentWithTag: 0) ?? []
        return (range, guesses)
    }
}

/// Builds the `EditorMenuActions` the context menu runs, wired to `tv`'s own
/// commands and to `MarkdownEditing`'s formatting entry points — never a
/// second implementation of marker insertion.
@MainActor
enum MarkdownEditorMenuActions {

    static func build(for tv: NSTextView) -> EditorMenuActions {
        EditorMenuActions(
            cut: { tv.cut(nil) },
            copy: { tv.copy(nil) },
            paste: { tv.paste(nil) },
            selectAll: { tv.selectAll(nil) },
            link: { wrapAsWikiLink(in: tv) },
            code: { MarkdownEditorTyping.toggleWrap(in: tv, with: "`") },
            heading: { toggleHeading(in: tv) },
            replace: { replacement in replaceWordAtCaret(in: tv, with: replacement) },
            ignoreSpelling: {
                if let word = wordAtCaret(in: tv) {
                    NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: 0)
                }
            },
            learnSpelling: {
                if let word = wordAtCaret(in: tv) { NSSpellChecker.shared.learnWord(word) }
            })
    }

    private static func wordAtCaret(in tv: NSTextView) -> String? {
        guard let range = WordAtPoint.range(in: tv.string, atUTF16: tv.selectedRange().location)
        else { return nil }
        return (tv.string as NSString).substring(with: range)
    }

    private static func replaceWordAtCaret(in tv: NSTextView, with replacement: String) {
        guard let range = WordAtPoint.range(in: tv.string, atUTF16: tv.selectedRange().location)
        else { return }
        let text = (tv.string as NSString).replacingCharacters(in: range, with: replacement)
        let selection = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        MarkdownEditorTyping.apply(EditResult(text: text, selection: selection), to: tv)
    }

    /// `[[…]]`, the same wiki-link syntax `MarkdownEditing.linkInsertion`
    /// produces when a completion is accepted — `toggleWrap` cannot make this
    /// edit itself, since its open and close delimiters are always identical.
    private static func wrapAsWikiLink(in tv: NSTextView) {
        let selection = tv.selectedRange()
        let ns = tv.string as NSString
        let inner = ns.substring(with: selection)
        let text = ns.replacingCharacters(in: selection, with: "[[" + inner + "]]")
        let cursor = NSRange(location: selection.location + 2, length: selection.length)
        MarkdownEditorTyping.apply(EditResult(text: text, selection: cursor), to: tv)
    }

    /// Toggles a level-2 `## ` prefix on the caret's line. There is no
    /// existing heading transform in `MarkdownEditing` to reuse — `toggleWrap`
    /// wraps a SELECTION on both sides, and a heading marker is a LINE prefix.
    private static func toggleHeading(in tv: NSTextView) {
        let ns = tv.string as NSString
        let selection = tv.selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = ns.substring(with: lineRange)
        let prefix = "## "
        let newLine: String
        let delta: Int
        if line.hasPrefix(prefix) {
            newLine = String(line.dropFirst(prefix.count))
            delta = -(prefix as NSString).length
        } else {
            newLine = prefix + line
            delta = (prefix as NSString).length
        }
        let text = ns.replacingCharacters(in: lineRange, with: newLine)
        let cursor = NSRange(location: max(lineRange.location, selection.location + delta),
                             length: selection.length)
        MarkdownEditorTyping.apply(EditResult(text: text, selection: cursor), to: tv)
    }
}
