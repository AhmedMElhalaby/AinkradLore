import AppKit
import SwiftUI

/// The `[[` completion popup's behaviour: what the caret is currently
/// completing, which rows to offer, and what a picked row writes.
///
/// Split out of `MarkdownEditor.swift` for the 500-line ceiling. It is a
/// coherent unit rather than an arbitrary cut: every function here answers one
/// question — what does the text around the caret MEAN right now — and they
/// share the invariant that makes the feature safe, which is that the range
/// replaced on accept is the same range the prefix was read from.
extension MarkdownEditor.Coordinator {

        /// The typed prefix for the current caret, or `nil`.
        ///
        /// Runs per keystroke, so it allocates nothing proportional to the
        /// document: `Range(_:in:)` converts the UTF-16 caret to a
        /// `String.Index` without copying, and the scan itself stops at the
        /// start of the current line.
        func activePrefix(in tv: NSTextView) -> String? {
            guard tv.selectedRange().length == 0 else { return nil }
            let text = tv.string
            guard let caret = Range(NSRange(location: tv.selectedRange().location, length: 0),
                                    in: text)?.lowerBound else { return nil }
            return LinkCompletionContext.activePrefix(in: text, caret: caret)
        }

        /// Internal for the same cross-file reason as `pendingEdit`: its one
        /// caller, `textDidChange`, lives in `MarkdownEditorEditPath.swift`.
        func refreshCompletions() {
            guard let tv = textView, let completions,
                  let prefix = activePrefix(in: tv) else {
                completionPanel.hide(); return
            }
            // A `#` in the prefix switches the list to that document's
            // HEADINGS. Checked before the document query so typing
            // `[[Design#` stops offering documents the moment the fragment
            // begins — the user has already chosen the document.
            let items: [LinkCompletionItem]
            if let query = LinkCompletionContext.headingQuery(inPrefix: prefix),
               let headingCompletions {
                // The row carries the VERIFIED target, not what was typed —
                // see `HeadingCompletions.insertTarget`.
                let found = headingCompletions(query.document, query.heading)
                items = (found?.headings ?? []).map {
                    .heading(document: found?.insertTarget ?? query.document, text: $0)
                }
            } else {
                let rows = completions(prefix)
                items = Self.completionItems(for: prefix, matches: rows,
                                             canCreate: createLinkedNote != nil)
            }
            guard !items.isEmpty else { completionPanel.hide(); return }
            completionPanel.show(matches: items, tokens: tokens,
                                 caretRect: caretRect(in: tv), over: tv)
        }

        /// Scrolling moves the caret on screen but changes nothing about what
        /// is being completed — so this re-places the panel and never re-queries.
        func repositionCompletions() {
            // Scrolling slides the text out from under a STATIONARY pointer,
            // so whatever the preview is describing is no longer what the
            // pointer is over. The completion panel repositions because it
            // tracks the CARET, which moved with the text; this tracks the
            // pointer, which did not.
            if previewPanel.isVisible {
                hoverTask?.cancel()
                hoverTask = nil
                previewPanel.hide()
            }
            guard completionPanel.isVisible, let tv = textView else { return }
            completionPanel.reposition(caretRect: caretRect(in: tv), over: tv)
        }

        func caretRect(in tv: NSTextView) -> NSRect {
            tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
        }

        /// Replaces the typed prefix with a target that resolves back to `row`,
        /// closes the link, and leaves the caret AFTER the `]]` so typing
        /// continues in prose.
        /// The rows the popup offers for a typed prefix.
        ///
        /// Pure and `static` so the one rule worth stating — WHEN a create row
        /// appears — is asserted directly. It appears only when the typed text
        /// is not already the name of something offered: a "Create «Design»"
        /// row underneath an existing `Design` invites making a second
        /// document with the same name, which is the one outcome a vault
        /// cannot easily undo.
        static func completionItems(for prefix: String, matches: [IndexRow],
                                    canCreate: Bool) -> [LinkCompletionItem] {
            let trimmed = prefix.trimmingCharacters(in: .whitespaces)
            var items = matches.map { LinkCompletionItem.document($0) }
            guard canCreate, !trimmed.isEmpty else { return items }
            let exists = matches.contains { row in
                let name = row.title.isEmpty ? row.path.lastPathComponent : row.title
                return name.compare(trimmed, options: .caseInsensitive) == .orderedSame
            }
            // LAST, never first: the common case is picking a note that
            // exists, and a create row at the top is one stray Return away
            // from a duplicate.
            if !exists { items.append(.create(trimmed)) }
            return items
        }

        /// Handles a picked row.
        func accept(_ item: LinkCompletionItem) {
            switch item {
            case .document(let row):
                insert(linkText: linkTarget(row))
            case .heading(let document, let text):
                // The document name is re-emitted with the fragment so the
                // insertion replaces the whole typed prefix — the caret sits
                // after `#`, and inserting only the heading would leave
                // `[[Design#Design#Overview]]`.
                insert(linkText: "\(document)#\(text)")
            case .create(let name):
                // Created BEFORE the text is inserted, so a refused create
                // (no vault, an invalid name) leaves the document untouched
                // rather than writing a link to a note that was never made.
                guard createLinkedNote?(name) == true else {
                    completionPanel.hide(); return
                }
                insert(linkText: name)
            }
        }

        func insert(linkText: String) {
            guard let tv = textView, let prefix = activePrefix(in: tv) else {
                completionPanel.hide(); return
            }
            let insertion = linkText + "]]"
            // The `]]` may ALREADY be there: `[` auto-pairs, so typing `[[`
            // leaves `[[]]` with the caret in the middle. `linkInsertionRange`
            // absorbs an existing closer into the replaced range, which is what
            // stops an accepted completion reading `[[Target]]]]`.
            let range = MarkdownEditing.linkInsertionRange(
                text: tv.string, caret: tv.selectedRange().location,
                prefixLength: prefix.utf16.count)
            // Through `shouldChangeText`/`didChangeText` so the edit is one
            // undo step and the delegate still fires.
            if tv.shouldChangeText(in: range, replacementString: insertion) {
                tv.textStorage?.replaceCharacters(in: range, with: insertion)
                tv.didChangeText()
            }
            tv.setSelectedRange(NSRange(location: range.location + (insertion as NSString).length,
                                        length: 0))
            completionPanel.hide()
        }
}
