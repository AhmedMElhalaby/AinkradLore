import AppKit

/// `NSTextView` that reports the two clicks the editor gives meaning to.
///
/// Moved out of `MarkdownEditor.swift` when the checkbox toggle was added:
/// that file was 489 of its 500 permitted lines and is about the editor's
/// AppKit wiring, while this one is about what a click MEANS.
///
/// Both hooks share one scheme, deliberately, rather than a second one being
/// invented for the checkbox: a handler receives the clicked UTF-16 offset and
/// reports whether it consumed the click; a `false` — or no handler at all —
/// falls straight through to `super.mouseDown`, so the caret still lands
/// exactly where the user clicked. Nothing here can swallow a click it did not
/// positively recognise.
///
/// Cmd-click for links, plain click for checkboxes, and that asymmetry is
/// intentional. Inside an editor the primary meaning of a click is "put the
/// caret here", so hijacking a plain click on a `[[…]]` span would make link
/// text the one run of characters the user cannot click into to fix a typo —
/// and a link span is long. A checkbox marker is ONE character wide, sits
/// between two brackets that remain freely clickable, and is the affordance
/// every markdown editor on this platform activates with a plain click. The
/// caret can still be placed on either side of the `[ ]`; only the interior
/// boundaries are claimed.
final class LinkTextView: NSTextView {
    /// Receives the clicked UTF-16 offset and reports whether it opened a link.
    /// The Bool matters: a Cmd-click that hits no link — or a document with no
    /// link handler at all, i.e. plain text — must fall through to AppKit so
    /// the caret still lands where the user clicked.
    var onCommandClick: (@MainActor (Int) -> Bool)?
    /// Receives the clicked UTF-16 offset of an unmodified single click and
    /// reports whether it toggled a task checkbox. Same fall-through contract.
    var onPlainClick: (@MainActor (Int) -> Bool)?
    /// Fires whenever focus leaves this view, including the routes that do not
    /// produce a `textDidEndEditing`.
    var onResignFirstResponder: (@MainActor () -> Void)?
    /// Fires when the view's WIDTH changes, which is the only input to where
    /// the text column sits — see `MarkdownEditorLayout`. Height changes are
    /// ignored, and a height change is what most `setFrameSize` calls are: the
    /// view grows as the document does.
    var onWidthChange: (@MainActor (CGFloat) -> Void)?
    private var lastNotifiedWidth: CGFloat = -1

    /// The resize hook. `updateNSView` is not one: SwiftUI does not re-run it
    /// for every frame of a live window resize, so a column centred only there
    /// would drift off-centre while the user drags the window edge.
    ///
    /// Cannot recurse: the handler sets `textContainerInset`, never the frame,
    /// and any frame change that follows carries the same width — which this
    /// guard drops.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - lastNotifiedWidth) > 0.5 else { return }
        lastNotifiedWidth = newSize.width
        onWidthChange?(newSize.width)
    }

    /// Code panels and blockquote bars to paint BEHIND the text. Set by the
    /// coordinator whenever styles are applied; see `MarkdownBlockBackgrounds`
    /// for why these are drawn rather than attributed.
    var blockBackgrounds: [MarkdownBlockBackgrounds.Region] = [] {
        didSet { if blockBackgrounds != oldValue { needsDisplay = true } }
    }
    /// The colours those regions are painted in, from the host theme.
    var blockBackgroundPalette: MarkdownBlockBackgrounds.Palette? {
        didSet { if blockBackgroundPalette != oldValue { needsDisplay = true } }
    }

    /// The one drawing hook. `super` first, so the view's own background is
    /// down before the block decoration goes on top of it and the text on top
    /// of that.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let palette = blockBackgroundPalette else { return }
        MarkdownBlockBackgrounds.draw(blockBackgrounds, palette: palette,
                                      in: self, dirtyRect: rect)
    }

    /// Modifiers that mean the user is doing something other than "activate
    /// what is under the pointer": extending a selection, opening a context
    /// menu, or whatever the host binds Option-click to.
    private static let selectionModifiers: NSEvent.ModifierFlags =
        [.shift, .option, .control, .command]

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFirstResponder?() }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.command) {
            if onCommandClick?(characterIndexForInsertion(at: point)) == true { return }
            super.mouseDown(with: event)
            return
        }
        // Single, unmodified click only. A double-click is select-the-word and
        // a drag starts from a click too — neither should flip a checkbox.
        if event.clickCount == 1,
           event.modifierFlags.intersection(Self.selectionModifiers).isEmpty,
           onPlainClick?(characterIndexForInsertion(at: point)) == true { return }
        super.mouseDown(with: event)
    }
}

extension MarkdownEditor.Coordinator {

    /// Flips the task checkbox whose marker the click landed in, and reports
    /// whether it did. `false` means "not mine" and the click proceeds to
    /// AppKit untouched.
    ///
    /// THE EDIT PATH. The toggle is a one-character `replaceCharacters`
    /// bracketed by `shouldChangeText(in:replacementString:)` and
    /// `didChangeText()` — the identical pair `insert(_ row:)` uses for a
    /// picked completion, and the pair AppKit itself uses for a keystroke. That
    /// bracketing is what makes the toggle:
    ///
    /// - one undo step (`allowsUndo` + `shouldChangeText` registers it);
    /// - a `textDidChange` delegate call, which writes `text.wrappedValue` and
    ///   so drives `MarkdownDocumentEditor`'s `.onChange(of: body_)` →
    ///   `engine.note.body = body_` → `ctx.onChange()` → `session.markChanged()`
    ///   → `isDirty = true` and the 500 ms debounced autosave, which calls
    ///   `saveNow()` and therefore passes the mtime external-change guard;
    /// - a `shouldChangeTextIn` delegate call, which records `pendingEdit` so
    ///   the style cache SHIFTS rather than flashing the note back to plain
    ///   text for a debounce.
    ///
    /// Nothing here writes a file and nothing calls `saveNow()`. A toggle is
    /// indistinguishable from the user typing the character themselves, which
    /// is the only way it inherits every data-loss guard M1 and M2 built.
    ///
    /// THE OFFSET GUARD. `styleCache.spans` may lag the live text by up to one
    /// styling debounce — they are shifted between parses, not re-derived — so
    /// a cached span's offset is a CANDIDATE, never an authority.
    /// `TaskCheckbox.markerRange(forBracketSpan:in:)` re-reads `tv.string` at
    /// that offset and yields a range only if a real `[` marker `]` still sits
    /// there. When it does not, the click is dropped and falls through to
    /// ordinary caret placement: mis-styling a character is cosmetic, but
    /// mis-toggling one edits the user's note.
    @MainActor func toggleTask(atUTF16 index: Int) -> Bool {
        // A read-only session can never persist this — see `allowsTaskToggle`.
        guard allowsTaskToggle, let tv = textView, let storage = tv.textStorage else {
            return false
        }
        let ns = tv.string as NSString

        // ONE locator, shared with nothing that could disagree with it — see
        // `TaskCheckbox`. `items` already validates each cached span against
        // the LIVE text, so a span that has drifted is simply absent here.
        for item in TaskCheckbox.items(in: styleCache.spans, text: ns) {
            // The interior boundaries of `[x]` only: `characterIndexForInsertion`
            // snaps to the nearest boundary, so the marker's own offset and the
            // one just past it are "the pointer was over the marker character,
            // or over the inner half of a bracket". The bracket offsets stay
            // available for placing the caret beside the marker.
            guard index >= item.markerRangeUTF16.location,
                  index <= item.markerRangeUTF16.location + 1 else { continue }
            // Located from a cached span; the live text still decides what the
            // character becomes.
            guard let (marker, replacement) = TaskCheckbox.replacement(for: item, in: ns)
            else { continue }

            guard tv.shouldChangeText(in: marker, replacementString: replacement) else {
                return false
            }
            storage.replaceCharacters(in: marker, with: replacement)
            tv.didChangeText()
            // The click still means "the caret goes here", just after the
            // character it flipped — so typing continues where the user
            // pointed rather than wherever the caret happened to be.
            tv.setSelectedRange(NSRange(location: NSMaxRange(marker), length: 0))
            return true
        }
        return false
    }
}
