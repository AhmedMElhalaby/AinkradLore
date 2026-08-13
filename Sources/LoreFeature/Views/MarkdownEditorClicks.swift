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
    /// Fires whenever this view GAINS focus. `textDidBeginEditing` is not a
    /// substitute — `NSText` posts that only on the first EDIT after becoming
    /// first responder, not on becoming it, so clicking back into the editor
    /// without typing anything fired nothing at all until this was added.
    var onBecomeFirstResponder: (@MainActor () -> Void)?
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
            // Positioned by `EmbedGeometry.drawRect`, NOT by `rect.minX` —
            // for a collapsed, near-zero-width source run, TextKit places
            // that run against the LINE'S END margin, which for an RTL
            // paragraph is the right edge, not the left. Deriving the
            // origin from the paragraph's own writing direction and the
            // container's usable width instead is correct for both
            // directions and clamps an over-wide image to never overflow
            // either edge. `rect.minY` is still trusted — the diagnosed bug
            // is horizontal only.
            //
            // `EmbedGeometry.drawRect` answers in CONTAINER-local x.
            // `textContainerOrigin.x`, NOT `textContainerInset.width`,
            // translates that into this view's own coordinate space — see
            // `MarkdownBlockBackgrounds.columnX`'s doc comment: the inset
            // only happens to agree with the container's real origin while
            // the column is flush against the view edge, and
            // `MarkdownEditorLayout` centres a capped-width column, so on a
            // wide window the two part company and every embed image would
            // detach sideways from the code panels/quote bars that already
            // use `textContainerOrigin.x`. `lineFragmentPadding` (AppKit's
            // own 5pt default, never zeroed here) is passed through too —
            // fix round 1, Important 2 — because the OLD `rect.minX` code
            // included it for free (a glyph rect already accounts for line
            // fragment padding) and dropping it would shift every
            // previously-working top-level LTR embed 5pt left of where it
            // used to sit.
            let containerWidth = textContainer?.size.width ?? bounds.width
            let padding = textContainer?.lineFragmentPadding ?? 0
            let local = EmbedGeometry.drawRect(containerWidth: containerWidth,
                                               writingDirection: region.writingDirection,
                                               indent: region.indent,
                                               lineFragmentPadding: padding, imageSize: region.size)
            let drawRect = NSRect(x: local.origin.x + textContainerOrigin.x, y: rect.minY,
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

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
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

    /// Intercepts an image or file paste before AppKit's own handling —
    /// which, on a plain (`isRichText == false`) view, either discards image
    /// data outright (no rich-text storage to hold it) or, for a Finder file
    /// copy, inserts the raw path/filename as text, since `.fileURL` always
    /// rides alongside a string representation of that same path.
    ///
    /// THE RULE, in priority order:
    ///
    /// 1. **File URLs win, UNLESS a string on the pasteboard is independent
    ///    prose rather than a mechanical rendering of one of those files.**
    ///    If the pasteboard can produce `NSURL`s restricted to
    ///    `.urlReadingFileURLsOnly` (a Finder "Copy", or anything else
    ///    vending genuine file references) AND every non-empty string on the
    ///    pasteboard is accounted for as a representation of one of those
    ///    files (see `stringsRepresentOnlyFiles`), this routes to
    ///    `onDropFileURLs` — the SAME handler the drop path uses, not a
    ///    parallel one, so multi-file, per-file failure, and the read-only
    ///    guard all come for free. Fix round 1 checked ONLY for a fileURL
    ///    and ignored the string entirely, on the premise that Finder's
    ///    string is always just the path — true for Finder, but a
    ///    reinstatement of this file's own data-loss class the moment some
    ///    other app (Mail, Notes) vends a `.fileURL` for an attachment
    ///    ALONGSIDE genuine prose the user selected around it.
    ///    `.urlReadingFileURLsOnly` keeps an ordinary `http(s)` string
    ///    (Safari's "Copy Link") from being misread as a file to begin with.
    /// 2. Otherwise, if the pasteboard offers image bytes (`.png`/`.tiff`)
    ///    AND EITHER no string at all, OR a string that is merely the
    ///    image's own source reference rather than prose the user selected
    ///    (see `isImageSourceRepresentation`), the image is attached. This
    ///    is what makes Safari/Preview's "Copy Image" — bytes plus the
    ///    source page's URL as a string, no `.fileURL` — write the image
    ///    instead of pasting that URL: the owner's most common complaint.
    /// 3. Anything else with a string present falls straight through to
    ///    `super.paste(_:)`, exactly AppKit's own behaviour. This is the
    ///    data-loss regression guard: a genuine mixed copy (real prose
    ///    selected alongside an image or a file, in Notes/Keynote/Mail, or
    ///    most RTF copies which carry `.tiff` beside
    ///    `public.utf8-plain-text`) must paste the TEXT and write nothing,
    ///    the same as before this rule existed — see
    ///    `isImageSourceRepresentation`'s doc comment for the honest limits
    ///    of that test.
    ///
    /// KNOWN GAP, not a regression: a PROMISED file (`.fileContents` /
    /// `NSFilesPromisePboardType`, offered by some apps before the file is
    /// materialised on disk — no `NSURL` to read yet) is invisible to
    /// `fileURLs(on:)` and falls through this whole rule to `super.paste`.
    /// `performDragOperation` below has the identical gap for a promised
    /// DROP, so this is not new here; neither path is exercised by a test,
    /// and fixing it would mean adopting `NSFilePromiseReceiver`, a
    /// materially bigger change than this rule.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        if let onDropFileURLs, let urls = Self.fileURLs(on: pb), !urls.isEmpty,
           Self.stringsRepresentOnlyFiles(on: pb, urls: urls) {
            // Committed: this pasteboard is a file copy with no independent
            // prose riding along. Whatever the handler reports — full
            // success, partial success (some files written, per
            // `insertAttachments(fromDroppedFiles:)`), or total failure —
            // is the final answer. Falling through to `super` on failure
            // would be exactly the ORIGINAL bug: AppKit's default paste
            // would still insert the raw path as text.
            _ = onDropFileURLs(urls)
            return
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard let best = pb.availableType(from: imageTypes),
              let data = pb.data(forType: best) else {
            super.paste(sender)
            return
        }
        // `pb.string(forType:)`, not the earlier fix-round-1 guard of
        // `availableType(from: [.string]) == nil`: that gate blocked on the
        // TYPE being merely advertised, so a `.string` type present but
        // carrying no actual string data (rare, but a valid pasteboard
        // shape) would defer to text with nothing there to paste. Asking
        // for the string itself is the more precise question — "is there
        // real string content to weigh against the image" — and only
        // differs from the old gate in that one narrow, data-free edge.
        if let string = pb.string(forType: .string), !Self.isImageSourceRepresentation(string) {
            super.paste(sender)
            return
        }
        // `.png` is tried before `.tiff` because that is what `NSPasteboard`'s
        // screenshot/copy-image paths actually populate; TIFF is the
        // fallback some apps use instead.
        let ext = best == .png ? "png" : "tiff"
        let name = "Pasted image \(Self.pasteTimestampFormatter.string(from: Date())).\(ext)"
        if onPasteImage?(data, name) == true { return }
        super.paste(sender)
    }

    /// File URLs on the pasteboard, restricted to ones that are ACTUALLY
    /// file references — never an `http(s)` link that merely canonicalizes
    /// to a URL. `nil` when the pasteboard cannot produce any (the common
    /// case: no `.fileURL` type at all), so callers can tell "not a file
    /// paste" apart from "a file paste that happens to be empty", though the
    /// latter cannot occur in practice.
    private static func fileURLs(on pb: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard pb.canReadObject(forClasses: [NSURL.self], options: options) else { return nil }
        return pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
    }

    /// Whether every non-empty string on the pasteboard is accounted for as
    /// a mechanical rendering of one of `urls` — never independent prose.
    ///
    /// Checked PER `NSPasteboardItem`, not via `NSPasteboard.string
    /// (forType:)` on the pasteboard as a whole: that method only ever sees
    /// the FIRST item's string, which would miss a SEPARATE item carrying
    /// real prose — the shape a Mail or Notes selection of "some text plus
    /// an attachment" can plausibly produce (one item for the attachment's
    /// `.fileURL`, a different item for the surrounding text the user
    /// selected around it). An item with a string but no `.fileURL` of its
    /// own is exactly that case: its string cannot be a representation of
    /// ANY file, since it is not paired with one, so any non-blank string
    /// there fails the check immediately.
    private static func stringsRepresentOnlyFiles(on pb: NSPasteboard, urls: [URL]) -> Bool {
        guard let items = pb.pasteboardItems else { return true }
        for item in items {
            guard let string = item.string(forType: .string),
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard urls.contains(where: { Self.isRepresentation(string, of: $0) }) else { return false }
        }
        return true
    }

    /// Whether `string` is nothing more than a mechanical rendering of
    /// `url` — its absolute string, its filesystem path, or its last path
    /// component, with or without percent-encoding — as opposed to prose
    /// that merely happens to mention the file.
    private static func isRepresentation(_ string: String, of url: URL) -> Bool {
        guard let token = Self.singleToken(string) else { return false }
        if token == url.absoluteString || token == url.path || token == url.lastPathComponent {
            return true
        }
        if let decoded = token.removingPercentEncoding,
           decoded == url.absoluteString || decoded == url.path || decoded == url.lastPathComponent {
            return true
        }
        return false
    }

    /// Whether a string riding alongside image bytes looks like the image's
    /// own SOURCE reference (what Safari/Preview's "Copy Image" writes —
    /// the page or file the image came from) rather than prose the user
    /// independently selected. The test: the whole trimmed string is ONE
    /// token (see `singleToken`) and it parses as a URL with a scheme.
    ///
    /// HONEST LIMIT: this is a heuristic over pasteboard content, not a
    /// certainty. A genuine text selection that is itself a single bare URL
    /// with nothing else — copied deliberately, alongside an unrelated
    /// image, in some app — would be misread as the image's source and
    /// discarded rather than pasted. That case is judged rare enough (a
    /// prose selection consisting of exactly one URL and no other
    /// characters) to accept, because the alternative — always deferring to
    /// text whenever ANY string rides along — is what the owner hit: it
    /// makes "Copy Image" in Safari, the single most common source of this
    /// complaint, paste a URL every time instead of the image. Where the
    /// two goals conflict this narrowly, WHOLE SENTENCES OF PROSE (anything
    /// with a space) still always win over the image, per the guard this
    /// function backs — only a bare, spaceless, scheme-bearing token can
    /// ever be read as "this is the image's source, not the user's text".
    private static func isImageSourceRepresentation(_ string: String) -> Bool {
        guard let token = Self.singleToken(string),
              let url = URL(string: token), url.scheme != nil else { return false }
        return true
    }

    /// The one idea both `isRepresentation(_:of:)` and
    /// `isImageSourceRepresentation` are built on: trim the string, and
    /// treat it as a candidate "this is a MECHANICAL rendering, not prose"
    /// only if what remains has no internal whitespace at all. Real prose —
    /// a sentence, a caption, a filename mentioned in a sentence — almost
    /// always has a space somewhere; a raw path, filename, or URL never
    /// does. `nil` for anything blank or containing whitespace, which both
    /// callers treat as "not a mechanical representation of anything".
    private static func singleToken(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        return trimmed
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
