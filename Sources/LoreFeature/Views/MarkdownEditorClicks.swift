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
    /// Receives pasted image bytes and a generated filename, and reports
    /// whether it was handled (written as an attachment and inserted).
    /// `false` — or no handler — falls through to AppKit's own `paste(_:)`,
    /// same fall-through contract `onCommandClick`/`onPlainClick` use.
    var onPasteImage: (@MainActor (Data, String) -> Bool)?
    /// Receives the file URLs from a Finder drop and reports whether they
    /// were handled (copied in and inserted). Same fall-through contract.
    var onDropFileURLs: (@MainActor ([URL]) -> Bool)?

    /// File URLs are registered by `MarkdownEditor.makeNSView` right after
    /// construction, not here: `NSTextView` is an Objective-C class, and
    /// overriding its designated initializer to do this would drop the
    /// inherited `NSTextView(frame:)` convenience initializer that
    /// `makeNSView` actually calls. A plain (`isRichText == false`) text
    /// view does not accept a Finder drag by default the way a rich text
    /// view does, and the default rich-text behaviour (embedding the image
    /// as an `NSTextAttachment`) is not what a MARKDOWN source file wants
    /// anyway — Task 9 wants a `![[name]]` embed, not an attachment run.

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

    /// Resolved image embeds to paint where their (collapsed) source text
    /// sits — see `MarkdownEditor.Coordinator.applyEmbeds`. Drawn in
    /// `drawBackground`, same as `blockBackgrounds`: the embed's paragraph
    /// style already reserves the vertical room, so drawing before the text
    /// layer is enough — the collapsed source glyphs are visually empty and
    /// nothing else occupies that rect.
    var embedImages: [MarkdownEditor.Coordinator.EmbedImageRegion] = [] {
        didSet { if embedImages != oldValue { needsDisplay = true } }
    }

    /// The one drawing hook. `super` first, so the view's own background is
    /// down before the block decoration goes on top of it and the text on top
    /// of that.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let palette = blockBackgroundPalette {
            MarkdownBlockBackgrounds.draw(blockBackgrounds, palette: palette,
                                          in: self, dirtyRect: rect)
        }
        drawEmbedImages(in: rect)
    }

    /// Positions each region from its character rect at draw time, rather
    /// than caching a rect computed earlier: scrolling and resizing move
    /// glyph rects without changing the ranges `applyEmbeds` recorded them
    /// for.
    ///
    /// `firstRect(forCharacterRange:actualRange:)`, not `layoutManager`:
    /// `MarkdownStyleRenderer.viewportWindow` already documents why reading
    /// `layoutManager` on a TextKit 2 view silently downgrades the whole view
    /// to TextKit 1, and `caretRect(in:)` in `MarkdownEditor.swift` uses this
    /// same version-agnostic API for the identical reason. It answers in
    /// SCREEN coordinates, so the result is converted back through the
    /// window before comparing against `dirtyRect`, which is in this view's
    /// own coordinate space.
    private func drawEmbedImages(in dirtyRect: NSRect) {
        guard !embedImages.isEmpty, let window else { return }
        for region in embedImages {
            let screenRect = firstRect(forCharacterRange: region.range, actualRange: nil)
            guard screenRect.width.isFinite, screenRect.height.isFinite else { continue }
            let windowRect = window.convertFromScreen(screenRect)
            let rect = convert(windowRect, from: nil)
            guard rect.intersects(dirtyRect) else { continue }
            // Left-aligned within the line's reserved height, at the image's
            // own scaled size — `applyEmbeds` already capped both dimensions
            // to the container.
            let drawRect = NSRect(x: rect.minX, y: rect.minY,
                                  width: region.size.width, height: region.size.height)
            // `draw(in:)` (the single-rect convenience) does NOT respect a
            // flipped coordinate system, and `NSTextView` IS flipped — fix
            // round 1, Important 5. Without `respectFlipped: true` every
            // inline embed image renders upside down. `.sourceOver` and
            // `fraction: 1` are the same defaults `draw(in:)` uses; only the
            // flip behaviour changes.
            region.image.draw(in: drawRect, from: .zero, operation: .sourceOver,
                              fraction: 1.0, respectFlipped: true, hints: nil)
        }
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

    // MARK: - Typing affordances

    /// Auto-pairing. `insertText` rather than a `doCommandBy` arm because
    /// ordinary characters never reach `doCommandBy`. Multi-character input —
    /// a paste, or an IME committing a phrase — is filtered out inside
    /// `MarkdownEditorTyping.typed`, so composition is untouched.
    ///
    /// Two inputs must never be auto-paired, because
    /// `MarkdownEditorTyping.typed` rebuilds the whole string around
    /// `selectedRange()` and knows nothing about either:
    ///
    /// - MARKED TEXT. An IME committing a single pair character (`[`, `(`, a
    ///   backtick, a quote) mid-composition would have its in-progress marked
    ///   range replaced with no `unmarkText`, leaving the input session
    ///   describing text that no longer exists.
    /// - An explicit `replacementRange`. Autocorrect, dictation and text
    ///   substitution target a range that is NOT the selection, so pairing
    ///   there inserts the pair in the wrong place and drops the correction.
    ///
    /// A `replacementRange` EQUAL to the current selection is ordinary typing
    /// described redundantly, and is allowed — refusing it would disable
    /// auto-pairing wherever AppKit chooses to spell the range out.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let targetsSelection = replacementRange.location == NSNotFound
            || replacementRange == selectedRange()
        if targetsSelection, !hasMarkedText() {
            let typed = (string as? String) ?? (string as? NSAttributedString)?.string
            if let typed, MarkdownEditorTyping.typed(typed, in: self) { return }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: - Paste and drop attachments

    /// Intercepts an image paste (screenshot, Preview copy, …) before
    /// AppKit's own handling — which, on a plain (`isRichText == false`)
    /// view, would just discard image data since there is no rich-text
    /// storage to hold it.
    ///
    /// ONLY when the pasteboard has NO string representation at all.
    /// `NSPasteboard.availableType(from:)` reports whether a type is
    /// PRESENT, not whether it is the pasteboard's PREFERRED one — an
    /// earlier version of this method checked `availableType(from: [.png,
    /// .tiff])` alone and hijacked any MIXED copy: an image dragged out of
    /// Safari, Notes or Keynote, and most RTF copies, carry `.tiff`
    /// ALONGSIDE `public.utf8-plain-text`, and that version wrote the image
    /// as an attachment while silently discarding the text the user
    /// actually meant to paste. A pasteboard offering a string type is
    /// treated as a text paste, full stop, and falls straight through to
    /// `super.paste(_:)` — exactly AppKit's own behaviour — regardless of
    /// what else rides along with it. `.png` is tried before `.tiff`
    /// because that is what `NSPasteboard`'s screenshot/copy-image paths
    /// actually populate; TIFF is the fallback some apps use instead.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard pb.availableType(from: [.string]) == nil,
              let best = pb.availableType(from: imageTypes),
              let data = pb.data(forType: best) else {
            super.paste(sender)
            return
        }
        let ext = best == .png ? "png" : "tiff"
        let name = "Pasted image \(Self.pasteTimestampFormatter.string(from: Date())).\(ext)"
        if onPasteImage?(data, name) == true { return }
        super.paste(sender)
    }

    /// `yyyy-MM-dd HH.mm.ss`: colons are illegal in filenames on some
    /// volumes, so `HH.mm.ss` stands in for the usual `HH:mm:ss`. The
    /// pasteboard's timestamp is the only thing that distinguishes one paste
    /// from the next — without it, every image pasted into a note would
    /// collide on the same name and stack up as "image 2", "image 3", ….
    private static let pasteTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard onDropFileURLs != nil,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self]) else {
            return super.draggingEntered(sender)
        }
        return .copy
    }

    /// Files dropped from Finder are COPIED into the vault, never referenced
    /// in place — see `LoreStore.writeAttachment(copying:besideNote:)`'s doc
    /// comment.
    ///
    /// Falls through to `super` (AppKit's default drop handling) only when
    /// there is NO handler installed, or the pasteboard carries no file
    /// URLs at all — the same two "this drop is not mine" cases
    /// `draggingEntered` already reports as not `.copy`. Once a handler IS
    /// installed and file URLs ARE present, this drop is fully owned:
    /// whatever `onDropFileURLs` reports — success or failure — is the
    /// final answer. Falling through to `super` on failure was the bug:
    /// with `.fileURL` registered, AppKit's own default handling inserts
    /// the raw file PATH as text, so a write that failed (permissions, disk
    /// full, outside-vault guard) would otherwise still leave something
    /// behind in the document — just the wrong something. A failed drop
    /// must insert nothing.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let onDropFileURLs else { return super.performDragOperation(sender) }
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
        return onDropFileURLs(urls)
    }

    /// Cmd-B / Cmd-I. Handled here rather than through `toggleBoldface(_:)`
    /// because those selectors arrive only from a Font menu, which a plugin's
    /// host window need not have.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, window?.firstResponder === self {
            switch event.charactersIgnoringModifiers {
            case "b": MarkdownEditorTyping.toggleWrap(in: self, with: "**"); return true
            case "i": MarkdownEditorTyping.toggleWrap(in: self, with: "*"); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
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

    /// Writes pasted image bytes as an attachment beside the note (via
    /// `EditorContext.writePastedImage`) and inserts the resulting
    /// `![[name]]` embed at the caret. `false` means declined or failed —
    /// no vault, no `writePastedImage` handler installed, or the write
    /// itself threw — and `LinkTextView.paste(_:)` falls through to AppKit's
    /// default paste, exactly like a Cmd-click that hits no link.
    @discardableResult
    @MainActor func insertAttachment(fromPastedImage data: Data, name: String) -> Bool {
        guard let writePastedImage, let embed = writePastedImage(data, name) else { return false }
        insertAtCaret(embed)
        return true
    }

    /// Copies each dropped file into the vault beside the note (via
    /// `EditorContext.writeDroppedFile`) and inserts every embed that
    /// succeeded, one per line, at the caret. A partial failure (one file
    /// copies, another does not — e.g. a permissions error mid-drop) still
    /// inserts what DID succeed rather than discarding it; only a drop where
    /// EVERY file failed reports `false` and falls through to AppKit's
    /// default drop handling.
    @discardableResult
    @MainActor func insertAttachments(fromDroppedFiles urls: [URL]) -> Bool {
        guard let writeDroppedFile else { return false }
        let embeds = urls.compactMap { writeDroppedFile($0) }
        guard !embeds.isEmpty else { return false }
        insertAtCaret(embeds.joined(separator: "\n"))
        return true
    }

    /// The shared insertion primitive for both attachment paths. Goes
    /// through `shouldChangeText`/`didChangeText` — the identical bracketing
    /// `insert(_ row:)` and `toggleTask(atUTF16:)` use — so an attachment
    /// insert is ONE undo step and fires the same `textDidChange` delegate
    /// call that updates `text.wrappedValue`, shifts the style cache, and
    /// (through `ctx.onChange()`) marks the document dirty for autosave.
    /// Replaces the current selection, same as typing over it — this is the
    /// ONLY sanctioned way this feature touches document text or offsets.
    @MainActor private func insertAtCaret(_ insertion: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: insertion) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: insertion)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + (insertion as NSString).length,
                                    length: 0))
    }
}
