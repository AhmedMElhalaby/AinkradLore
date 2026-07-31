import AppKit

/// Applies the pure `MarkdownEditing` transforms to a live text view, each as
/// ONE undo group.
///
/// Lives apart from `MarkdownEditor.swift` only because that file is at its
/// line cap; conceptually this is the keyboard half of the editor.
enum MarkdownEditorTyping {

    /// Returns true when the edit was applied, which the caller returns from
    /// `doCommandBy` to stop AppKit also handling the key.
    ///
    /// Goes through `shouldChangeText(in:replacementString:)` so the text
    /// view's own undo registration, delegate notifications and autosave
    /// bookkeeping all run — bypassing it with a direct `textStorage` mutation
    /// is what produces edits the autosave never learns about.
    ///
    /// THAT CALL is what makes the affordance one undo step: it registers the
    /// single reverse action, before the grouping below opens, and the mutation
    /// underneath is one `replaceCharacters`. The explicit grouping is belt and
    /// braces for anything that might later register a second action inside it;
    /// it is not what delivers the guarantee.
    @MainActor
    @discardableResult
    static func apply(_ result: EditResult, to tv: NSTextView) -> Bool {
        // A transform can legitimately return the text unchanged — outdenting
        // at column zero does. That keystroke is still handled (swallowed), but
        // it must not push a do-nothing entry onto the undo stack, or the next
        // Cmd-Z appears to do nothing at all.
        guard result.text != tv.string else {
            tv.setSelectedRange(result.selection)
            return true
        }
        let whole = NSRange(location: 0, length: (tv.string as NSString).length)
        guard tv.shouldChangeText(in: whole, replacementString: result.text) else { return false }
        tv.undoManager?.beginUndoGrouping()
        tv.textStorage?.replaceCharacters(in: whole, with: result.text)
        tv.setSelectedRange(result.selection)
        tv.undoManager?.endUndoGrouping()
        tv.didChangeText()
        return true
    }

    /// Routes an editing selector to its transform. Returns false — meaning
    /// "AppKit, do your default" — whenever the transform declines, which is
    /// what keeps plain newlines, tab insertion and IME behaviour intact.
    @MainActor
    static func handle(_ selector: Selector, in tv: NSTextView) -> Bool {
        let text = tv.string
        let selection = tv.selectedRange()
        let result: EditResult?
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            result = MarkdownEditing.continueList(text: text, selection: selection)
        case #selector(NSResponder.insertTab(_:)):
            result = MarkdownEditing.indent(text: text, selection: selection, by: 1)
        case #selector(NSResponder.insertBacktab(_:)):
            result = MarkdownEditing.indent(text: text, selection: selection, by: -1)
        default:
            return false
        }
        guard let result else { return false }
        return apply(result, to: tv)
    }

    /// Auto-pairing for a single typed character. Returns false for everything
    /// else — including multi-character input, which is a paste or an IME
    /// commit and must never be reinterpreted as a bracket.
    @MainActor
    static func typed(_ string: String, in tv: NSTextView) -> Bool {
        guard string.count == 1 else { return false }
        guard let result = MarkdownEditing.autoPair(text: tv.string,
                                                    selection: tv.selectedRange(),
                                                    typing: string) else { return false }
        return apply(result, to: tv)
    }

    /// Cmd-B / Cmd-I. Always produces a result, so it always applies.
    @MainActor
    static func toggleWrap(in tv: NSTextView, with delimiter: String) {
        apply(MarkdownEditing.toggleWrap(text: tv.string,
                                         selection: tv.selectedRange(),
                                         with: delimiter),
              to: tv)
    }
}
