import SwiftUI
import AppKit
import AinkradAppKit

public struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let tokens: HostThemeTokens
    /// Rows to offer for the current `[[` prefix. `nil` disables completion
    /// entirely — which is how plain-text documents get no link affordances.
    let completions: (@MainActor (String) -> [IndexRow])?
    /// Called with the raw target of a Cmd-clicked `[[…]]` span. `nil` disables
    /// click-to-open.
    let onOpenLink: (@MainActor (String) -> Void)?
    /// Resolves an `![[target]]` embed's raw target to a file, for
    /// `EmbedRendering`. `nil` — the default — makes every embed render
    /// `.unresolved` (plain wikilink colouring), which is the right answer
    /// for an engine with no link layer, exactly like `completions == nil`.
    let resolveEmbedTarget: (@MainActor (String) -> URL?)?
    /// What a picked row inserts. Defaults to the store-blind approximation.
    let linkTarget: @MainActor (IndexRow) -> String
    /// A UTF-16 offset (into `text`) to scroll the caret to and select. Set by
    /// a caller — `OutlineSection` — and cleared back to `nil` once handled,
    /// so re-clicking the same heading still fires: `updateNSView` only acts
    /// on a non-nil value, never on "the value changed".
    let scrollTarget: Binding<Int?>
    /// Whether clicking a `[ ]` marker flips it. Off by default, so a document
    /// type that has no task lists — and, crucially, a READ-ONLY session, whose
    /// `markChanged()` is a no-op and whose saves are refused — offers no
    /// affordance it cannot honour. See `MarkdownEditorClicks.swift`.
    let allowsTaskToggle: Bool
    /// See `EditorContext.writePastedImage`. `nil` disables the paste
    /// interception entirely, so a document with no attachment story falls
    /// straight through to AppKit's default paste — exactly the
    /// `completions == nil` / `onOpenLink == nil` pattern above.
    let writePastedImage: (@MainActor (Data, String) -> String?)?
    /// See `EditorContext.writeDroppedFile`. `nil` disables the drop
    /// destination.
    let writeDroppedFile: (@MainActor (URL) -> String?)?
    /// Fired on every selection change with the live document text and
    /// selection — the host's context-menu wiring (`MarkdownEditorMenu.swift`)
    /// uses this to keep its menu items current without reaching back into
    /// AppKit itself. See that file for why the items cannot be computed at
    /// the exact moment of a right-click.
    let onSelectionChange: (@MainActor (String, NSRange, Int) -> Void)?
    /// Called once the text view exists, with the actions its own context
    /// menu should run. See `MarkdownEditorMenu.swift`.
    let registerMenuActions: (@MainActor (EditorMenuActions) -> Void)?

    public init(text: Binding<String>, tokens: HostThemeTokens,
                completions: (@MainActor (String) -> [IndexRow])? = nil,
                onOpenLink: (@MainActor (String) -> Void)? = nil,
                resolveEmbedTarget: (@MainActor (String) -> URL?)? = nil,
                linkTarget: @escaping @MainActor (IndexRow) -> String
                    = { LinkCompletionContext.insertableTarget(for: $0) },
                scrollTarget: Binding<Int?> = .constant(nil),
                allowsTaskToggle: Bool = false,
                writePastedImage: (@MainActor (Data, String) -> String?)? = nil,
                writeDroppedFile: (@MainActor (URL) -> String?)? = nil,
                onSelectionChange: (@MainActor (String, NSRange, Int) -> Void)? = nil,
                registerMenuActions: (@MainActor (EditorMenuActions) -> Void)? = nil) {
        self._text = text; self.tokens = tokens
        self.completions = completions; self.onOpenLink = onOpenLink
        self.resolveEmbedTarget = resolveEmbedTarget
        self.linkTarget = linkTarget
        self.scrollTarget = scrollTarget
        self.allowsTaskToggle = allowsTaskToggle
        self.writePastedImage = writePastedImage
        self.writeDroppedFile = writeDroppedFile
        self.onSelectionChange = onSelectionChange
        self.registerMenuActions = registerMenuActions
    }

    public func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than via `NSTextView.scrollableTextView()`
        // because the text view has to be a subclass — Cmd-click detection has
        // no delegate hook, only `mouseDown(with:)`.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        // Markdown source, not prose. macOS's automatic substitutions turn `"`
        // into typographic quotes and `--` into an em dash, which corrupts the
        // very characters the parser reads — and, for `"`, gives the key two
        // owners, since `MarkdownEditing.pairs` also auto-pairs it. Which one
        // won depended on a System Settings toggle; now neither does.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(tokens.background)
        tv.insertionPointColor = NSColor(tokens.accentPrimary)
        // Margins and measure come from the theme, and are both a function of
        // the view's width — see `MarkdownEditorLayout`. Set once here for the
        // initial size, then kept in sync by `onWidthChange` via
        // `applyContainerGeometry`, which owns both together so they cannot
        // drift apart on resize.
        let initialTheme = MarkdownTheme(tokens: tokens)
        tv.textContainerInset = MarkdownEditorLayout.containerInset(
            forViewWidth: tv.bounds.width, theme: initialTheme)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(
            width: MarkdownEditorLayout.containerWidth(forViewWidth: tv.bounds.width,
                                                        theme: initialTheme),
            height: .greatestFiniteMagnitude)
        tv.onWidthChange = { [weak coordinator = context.coordinator] width in
            coordinator?.applyContainerGeometry(forWidth: width)
        }
        tv.onCommandClick = { [weak coordinator = context.coordinator] index in
            coordinator?.openLink(atUTF16: index) ?? false
        }
        tv.onPlainClick = { [weak coordinator = context.coordinator] index in
            coordinator?.toggleTask(atUTF16: index) ?? false
        }
        // Losing first responder INSIDE the same window — clicking the title
        // field, the sidebar, another pane — is not covered by
        // `hidesOnDeactivate`, and would otherwise leave a `.popUpMenu`-level
        // panel floating over the UI. `textDidEndEditing` covers the common
        // routes; this covers the rest (focus moved by keyboard, by the shell,
        // or to a control that does not end editing).
        tv.onResignFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.completionPanel.hide()
            // `false`, not a live read: at this point `NSWindow` has not yet
            // reassigned first responder away from `tv` (see
            // `revealForSelectionChange`'s doc comment), so a live read would
            // still answer "focused" and never hide the markers.
            coordinator?.revealForSelectionChange(forcedFocus: false)
        }
        tv.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.revealForSelectionChange(forcedFocus: true)
        }
        tv.onPasteImage = { [weak coordinator = context.coordinator] data, name in
            coordinator?.insertAttachment(fromPastedImage: data, name: name) ?? false
        }
        tv.onDropFileURLs = { [weak coordinator = context.coordinator] urls in
            coordinator?.insertAttachments(fromDroppedFiles: urls) ?? false
        }
        // See `LinkTextView`'s doc comment on why this is registered here,
        // post-construction, rather than in an overridden initializer.
        tv.registerForDraggedTypes([.fileURL])
        scroll.documentView = tv

        // The caret moves under the list when the document scrolls, so the list
        // has to follow it.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: scroll.contentView)

        context.coordinator.textView = tv
        context.coordinator.allowsTaskToggle = allowsTaskToggle
        context.coordinator.resolveEmbedTarget = resolveEmbedTarget ?? { _ in nil }
        context.coordinator.writePastedImage = writePastedImage
        context.coordinator.writeDroppedFile = writeDroppedFile
        context.coordinator.stylingNotice = Self.addStylingNotice(to: scroll, tokens: tokens)
        context.coordinator.onSelectionChange = onSelectionChange
        tv.string = text
        context.coordinator.applyStyles()
        // The text view exists now, so the closures that need it (cut, copy,
        // the formatting actions) can be built once, here, rather than
        // re-derived on every menu presentation. Deferred to the next
        // run-loop turn, same as `scrollTarget` above and for the same
        // reason: `makeNSView` runs INSIDE a SwiftUI view-update pass, and
        // writing a `@State` from there — which is what this callback does —
        // is the "modifying state during view update" trap: it produces the
        // purple runtime warning and leaves the first render's menu actions
        // at `.noop`.
        if let registerMenuActions {
            let actions = MarkdownEditorMenuActions.build(for: tv)
            DispatchQueue.main.async { registerMenuActions(actions) }
        }
        return scroll
    }

    /// A floating label, hidden unless the document is over the hard cap. Added
    /// to the SCROLL view rather than the text view so it stays put while the
    /// document scrolls under it, and so it never becomes part of the text.
    private static func addStylingNotice(to scroll: NSScrollView,
                                         tokens: HostThemeTokens) -> NSTextField {
        let notice = NSTextField(labelWithString:
            "Styling off — document over \(MarkdownDocumentModel.stylingHardCap / (1024 * 1024)) MB")
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = NSColor(tokens.accentSecondary)
        notice.isHidden = true
        notice.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            notice.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 6)
        ])
        return notice
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.completions = completions
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.resolveEmbedTarget = resolveEmbedTarget ?? { _ in nil }
        context.coordinator.linkTarget = linkTarget
        context.coordinator.allowsTaskToggle = allowsTaskToggle
        context.coordinator.writePastedImage = writePastedImage
        context.coordinator.writeDroppedFile = writeDroppedFile
        context.coordinator.onSelectionChange = onSelectionChange
        if tv.string != text { tv.string = text; context.coordinator.applyStyles() }
        tv.backgroundColor = NSColor(tokens.background)
        tv.insertionPointColor = NSColor(tokens.accentPrimary)
        context.coordinator.tokens = tokens
        context.coordinator.applyStyles()
        if let offset = scrollTarget.wrappedValue {
            context.coordinator.scrollToOffset(offset)
            // Scheduled, not written synchronously: `updateNSView` is inside a
            // view-update pass, and writing a `Binding` from there is the
            // "modifying state during view update" trap.
            DispatchQueue.main.async { scrollTarget.wrappedValue = nil }
        }
        // Deliberately no completion recompute here: `updateNSView` runs on
        // every ancestor redraw (theme change, banner appearing, window
        // resize), and querying the index on a redraw is both wasted work and
        // a way to make a popup appear when the user did not type.
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text, tokens: tokens) }

    /// Tearing the editor down must take the floating panel with it — this is
    /// the path that fires on a tab close and on a document switch (the pane
    /// re-`id`s the editor, so the old one is dismantled).
    ///
    /// `assumeIsolated` only where it is true. AppKit always dismantles on the
    /// main thread, but asserting that would turn a wrong assumption into a
    /// crash in the user's editor; off the main thread this degrades to a hop
    /// instead.
    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { coordinator.tearDown() }
        } else {
            Task { @MainActor in coordinator.tearDown() }
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var tokens: HostThemeTokens
        var completions: (@MainActor (String) -> [IndexRow])?
        var onOpenLink: (@MainActor (String) -> Void)?
        /// See `MarkdownEditor.resolveEmbedTarget`. Never left `nil` in
        /// practice — `makeNSView`/`updateNSView` always install at least the
        /// "no candidates" closure, matching how `completions` degrades.
        var resolveEmbedTarget: @MainActor (String) -> URL? = { _ in nil }
        var linkTarget: @MainActor (IndexRow) -> String
            = { LinkCompletionContext.insertableTarget(for: $0) }
        /// See `MarkdownEditor.allowsTaskToggle`.
        var allowsTaskToggle = false
        /// See `MarkdownEditor.writePastedImage`. `nil` — the default — means
        /// paste interception is off, matching `resolveEmbedTarget`'s
        /// "no capability supplied" shape before `makeNSView` installs the
        /// real one.
        var writePastedImage: (@MainActor (Data, String) -> String?)?
        /// See `MarkdownEditor.writeDroppedFile`.
        var writeDroppedFile: (@MainActor (URL) -> String?)?
        weak var textView: NSTextView?
        /// Shown only above the hard cap — the editor saying, in words, that it
        /// has stopped styling rather than leaving the user to wonder.
        weak var stylingNotice: NSTextField?
        let completionPanel = LinkCompletionPanel()
        /// See `MarkdownEditor.onSelectionChange`.
        var onSelectionChange: (@MainActor (String, NSRange, Int) -> Void)?

        /// Long enough that a burst of typing is one parse, short enough that
        /// the picture settles within a pause the user does not notice.
        static let parseDebounce: TimeInterval = 0.15

        /// The spans on screen and the string they describe. See
        /// `MarkdownStyleCache` for why this is not recomputed per call.
        ///
        /// Internal rather than `private(set)` only because the styling
        /// pipeline that mutates it now lives in `MarkdownEditorReveal.swift`,
        /// and Swift has no cross-file `private`. Nothing outside these two
        /// files writes it.
        var styleCache = MarkdownStyleCache()
        var parseTimer: Timer?
        /// Bumped per off-actor parse launched. A result whose generation is no
        /// longer the current one is discarded — see `parseNow`.
        var parseGeneration = 0
        var lastViewportWindow: NSRange?
        /// Block ranges, per-block span buckets and list depths for the CURRENT
        /// text. Rebuilt only when the text is re-rendered — never on a caret
        /// move, because `MarkdownReveal.blocks(in:)` scans the whole string.
        /// See `MarkdownEditorReveal.Index`.
        var revealIndex = MarkdownEditorReveal.Index.empty
        /// The INDICES of the blocks whose markers are currently revealed. The
        /// reveal state in full: if a caret move leaves this unchanged there is
        /// nothing to redraw, which is what keeps arrowing free of styling work.
        var revealedBlockIndices: Range<Int> = 0..<0
        /// First-responder state as of the last reveal pass. Compared against
        /// the LIVE state on every selection-change notification so a focus
        /// change — which does not move the caret and therefore would not flip
        /// `revealedBlockIndices` — still forces a full re-apply rather than
        /// being short-circuited away as "same selection, nothing to do".
        var lastRevealFocus = true
        /// Every `.embed` span's position, source range and owning block, for
        /// the CURRENT text. Rebuilt only when the text is re-rendered, from
        /// the same pass that builds `revealIndex` — never on a caret move.
        ///
        /// Exists because an embed's reveal is NOT a block-level property:
        /// `revealForSelectionChange` only reaches `restyleBlock` when the
        /// set of revealed BLOCKS flips, and arrowing from inside a block
        /// into an embed's own range is not a block flip — so without this
        /// an image stayed collapsed and drawn with the caret invisibly
        /// inside it until the next keystroke or the 150 ms debounce. Fix
        /// round 2, I6. Documents contain very few embeds (usually zero), so
        /// scanning this per caret move is cheap where scanning
        /// `styleCache.spans` would not be.
        var embedIndex: [(fullRange: NSRange, block: Int)] = []
        /// Which entries of `embedIndex` the selection is currently inside.
        /// The embed-level analogue of `revealedBlockIndices`: if a caret
        /// move leaves this unchanged there is no embed work to do.
        var revealedEmbedSpans: Set<Int> = []
        /// Whether the LAST text change was handled by the single-block fast
        /// path rather than a full render. Exists so the bail-out cases can be
        /// asserted directly instead of inferred from a timing — "it fell back"
        /// is the claim, and a timing cannot make it.
        /// Written only by `textDidChange` in `MarkdownEditorEditPath.swift`;
        /// internal rather than `private(set)` because Swift has no cross-file
        /// `private`, exactly as `styleCache` above.
        var lastEditTookFastPath = false
        /// What the last full `renderStyles()` pass actually painted, and from
        /// what. The redundant-redraw guard in `applyStyles` compares against
        /// it; `renderStyles` is the only writer, so it cannot claim a render
        /// that did not happen.
        ///
        /// `nil` until the first render, which is why a fresh editor always
        /// renders once.
        var renderedSnapshot: (text: String, tokens: HostThemeTokens)?
        /// How many times `applyStyles()` has been entered. Counts the CALLS,
        /// not the renders — the two differ exactly when the entry point
        /// decides it has nothing to do, which is the thing under measurement.
        ///
        /// Exists for the same reason `revealIndexBuilds` does: Task 10 could
        /// establish by reading that `updateNSView` calls `applyStyles()`
        /// unconditionally on every ancestor redraw, but "SwiftUI redraws this
        /// per keystroke" is a claim about SwiftUI's scheduling, and reading
        /// cannot settle it. See `MarkdownTypingLagBenchmark`.
        var applyStylesCalls = 0
        /// How many of those calls reached a full `renderStyles()`. The gap
        /// between this and `applyStylesCalls` is what the redundant-render
        /// guard buys.
        var applyStylesRenders = 0
        /// How many times the index has been built. Exists so a test can pin
        /// the claim that a caret move never rebuilds it — the claim is the
        /// whole performance contract of the reveal path, and an earlier
        /// version of this file made it without the code supporting it.
        var revealIndexBuilds = 0
        /// The DOCUMENT's dominant writing direction — the first strong
        /// (Unicode-alphabetic) character anywhere in the text, or `.leftToRight`
        /// when none exists. Rebuilt once per full `renderStyles()` pass, from
        /// the same string every other O(document) step in that pass already
        /// scans, and reused by `applyEmbeds` (both the full-render and the
        /// block-scoped `restyleBlock` path) as the LAST-RESORT fallback for an
        /// embed image's writing direction, when neither the paragraph before
        /// nor after it has a strong character of its own to go on — see
        /// `EmbedGeometry.contextualWritingDirection`. `restyleBlock` never
        /// recomputes it: it only ever runs on a caret move, never a text
        /// change, so the document this was computed from is still current.
        var documentWritingDirection: NSWritingDirection = .leftToRight
        /// How many BLOCKS the incremental reveal path has re-attributed. The
        /// caret contract is O(1) blocks per boundary crossing — two, the one
        /// leaving reveal and the one entering it — and "O(1)" is only a claim
        /// until something counts. Reset by the benchmark, never by the editor.
        var restyledBlockCount = 0
        /// The edit `shouldChangeTextIn` announced, consumed by the very next
        /// `textDidChange`. AppKit always pairs them, and anything that edits
        /// the storage WITHOUT the pair leaves the cache describing a stale
        /// string, which `applyStyles()` then repairs with a real parse.
        /// Internal, not private: `shouldChangeTextIn` and `textDidChange` now
        /// live in `MarkdownEditorEditPath.swift`, and Swift has no cross-file
        /// `private`. Nothing outside that file touches it.
        var pendingEdit: PendingEdit?

        var cachedSpansForTesting: [StyleSpan] { styleCache.spans }
        /// `nonisolated(unsafe)` only so `deinit` can unregister it. It is
        /// written and read exclusively on the main actor; `deinit` merely
        /// hands the opaque token back to `NotificationCenter`, which is
        /// thread-safe. Without the deinit an editor that is released without a
        /// `dismantleNSView` would leak one observer per document opened.
        nonisolated(unsafe) private var scrollObserver: (any NSObjectProtocol)?

        init(text: Binding<String>, tokens: HostThemeTokens) {
            self.text = text; self.tokens = tokens
            super.init()
            completionPanel.onPick = { [weak self] row in self?.insert(row) }
        }

        deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

        func observeScrolling(of clipView: NSClipView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.repositionCompletions()
                        self?.restyleForViewportIfNeeded()
                    }
                }
        }

        func tearDown() {
            completionPanel.hide()
            parseTimer?.invalidate()
            parseTimer = nil
            // Any in-flight off-actor parse now belongs to a torn-down editor;
            // bumping the generation makes its result arrive and be discarded.
            parseGeneration += 1
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
        }

        /// Caret moved without the text changing (click, arrow key). Cheap and
        /// index-free: it can only ever dismiss, never open, so it never asks
        /// the store for rows.
        public func textViewDidChangeSelection(_ notification: Notification) {
            // Live Preview's other half: which markers are hidden depends on
            // where the caret IS, not only on what was typed. Cheap by
            // construction — see `revealForSelectionChange`, which parses
            // nothing and usually does no work at all.
            revealForSelectionChange()
            if let tv = textView {
                onSelectionChange?(tv.string, tv.selectedRange(), tv.spellCheckerDocumentTag)
            }
            guard completionPanel.isVisible, let tv = textView else { return }
            if activePrefix(in: tv) == nil { completionPanel.hide() }
        }

        /// Focus left the editor. Nothing the list offers can be accepted from
        /// here, so it must not keep floating.
        ///
        /// Also re-applies reveal: `NSTextView` posts this as it loses first
        /// responder, and reveal is a function of focus, so a focus change
        /// must re-apply it exactly as a selection change does. `false` is
        /// passed explicitly rather than read live — see
        /// `tv.onResignFirstResponder`'s doc comment above; this delegate
        /// method is posted from the same `resignFirstResponder` call, before
        /// `NSWindow` has reassigned first responder away from `tv`.
        public func textDidEndEditing(_ notification: Notification) {
            completionPanel.hide()
            revealForSelectionChange(forcedFocus: false)
        }

        /// `NSText` posts this only on the first EDIT after becoming first
        /// responder, not on becoming it — `tv.onBecomeFirstResponder` above
        /// is what actually covers "focus arrived here". Kept for the case
        /// this DOES fire (a click that both focuses and edits in one step):
        /// the live read is correct here, since `becomeFirstResponder` has
        /// already returned by the time any edit can happen.
        public func textDidBeginEditing(_ notification: Notification) {
            revealForSelectionChange()
        }

        // MARK: - Keys the popup owns, and only while it is open

        public func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            // The panel owns Enter, Tab, the arrows and Escape WHILE IT IS
            // OPEN. Only once it is closed do Enter and Tab mean "continue this
            // list" and "indent it" — see `MarkdownEditorTyping`.
            guard completionPanel.isVisible else {
                return MarkdownEditorTyping.handle(selector, in: tv)
            }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                completionPanel.moveSelection(by: -1); return true
            case #selector(NSResponder.moveDown(_:)):
                completionPanel.moveSelection(by: 1); return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                completionPanel.pickSelected(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                completionPanel.hide(); return true
            default:
                return false
            }
        }

        // MARK: - Completion

        /// The typed prefix for the current caret, or `nil`.
        ///
        /// Runs per keystroke, so it allocates nothing proportional to the
        /// document: `Range(_:in:)` converts the UTF-16 caret to a
        /// `String.Index` without copying, and the scan itself stops at the
        /// start of the current line.
        private func activePrefix(in tv: NSTextView) -> String? {
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
            let rows = completions(prefix)
            guard !rows.isEmpty else { completionPanel.hide(); return }
            completionPanel.show(matches: rows, tokens: tokens,
                                 caretRect: caretRect(in: tv), over: tv)
        }

        /// Scrolling moves the caret on screen but changes nothing about what
        /// is being completed — so this re-places the panel and never re-queries.
        private func repositionCompletions() {
            guard completionPanel.isVisible, let tv = textView else { return }
            completionPanel.reposition(caretRect: caretRect(in: tv), over: tv)
        }

        private func caretRect(in tv: NSTextView) -> NSRect {
            tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
        }

        /// Replaces the typed prefix with a target that resolves back to `row`,
        /// closes the link, and leaves the caret AFTER the `]]` so typing
        /// continues in prose.
        private func insert(_ row: IndexRow) {
            guard let tv = textView, let prefix = activePrefix(in: tv) else {
                completionPanel.hide(); return
            }
            let insertion = linkTarget(row) + "]]"
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

        // MARK: - Click-to-open

        /// Returns whether a link was actually opened.
        func openLink(atUTF16 index: Int) -> Bool {
            guard let tv = textView, let onOpenLink else { return false }
            let text = tv.string
            guard let clicked = Range(NSRange(location: index, length: 0), in: text)?.lowerBound
            else { return false }
            let offset = text.distance(from: text.startIndex, to: clicked)
            guard let target = LinkCompletionContext.target(in: text, at: offset)
            else { return false }
            onOpenLink(target)
            return true
        }

        // The styling pipeline — parse debounce, render, reveal, container
        // geometry — lives in `MarkdownEditorReveal.swift`. This file is the
        // AppKit wiring and nothing else; see its line-count note.
    }
}
