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

    public init(text: Binding<String>, tokens: HostThemeTokens,
                completions: (@MainActor (String) -> [IndexRow])? = nil,
                onOpenLink: (@MainActor (String) -> Void)? = nil,
                linkTarget: @escaping @MainActor (IndexRow) -> String
                    = { LinkCompletionContext.insertableTarget(for: $0) },
                scrollTarget: Binding<Int?> = .constant(nil),
                allowsTaskToggle: Bool = false) {
        self._text = text; self.tokens = tokens
        self.completions = completions; self.onOpenLink = onOpenLink
        self.linkTarget = linkTarget
        self.scrollTarget = scrollTarget
        self.allowsTaskToggle = allowsTaskToggle
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
        // Margins and measure come from the theme, and are a function of the
        // view's width — see `MarkdownEditorLayout`. Set once here for the
        // initial size, then maintained by `onWidthChange`.
        tv.textContainerInset = MarkdownEditorLayout.containerInset(
            forViewWidth: tv.bounds.width, theme: MarkdownTheme(tokens: tokens))
        tv.onWidthChange = { [weak coordinator = context.coordinator] width in
            coordinator?.applyContainerInset(forWidth: width)
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
        }
        scroll.documentView = tv

        // The caret moves under the list when the document scrolls, so the list
        // has to follow it.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: scroll.contentView)

        context.coordinator.textView = tv
        context.coordinator.allowsTaskToggle = allowsTaskToggle
        context.coordinator.stylingNotice = Self.addStylingNotice(to: scroll, tokens: tokens)
        tv.string = text
        context.coordinator.applyStyles()
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
        context.coordinator.linkTarget = linkTarget
        context.coordinator.allowsTaskToggle = allowsTaskToggle
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
        var linkTarget: @MainActor (IndexRow) -> String
            = { LinkCompletionContext.insertableTarget(for: $0) }
        /// See `MarkdownEditor.allowsTaskToggle`.
        var allowsTaskToggle = false
        weak var textView: NSTextView?
        /// Shown only above the hard cap — the editor saying, in words, that it
        /// has stopped styling rather than leaving the user to wonder.
        weak var stylingNotice: NSTextField?
        let completionPanel = LinkCompletionPanel()

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
        /// How many times the index has been built. Exists so a test can pin
        /// the claim that a caret move never rebuilds it — the claim is the
        /// whole performance contract of the reveal path, and an earlier
        /// version of this file made it without the code supporting it.
        var revealIndexBuilds = 0
        /// How many BLOCKS the incremental reveal path has re-attributed. The
        /// caret contract is O(1) blocks per boundary crossing — two, the one
        /// leaving reveal and the one entering it — and "O(1)" is only a claim
        /// until something counts. Reset by the benchmark, never by the editor.
        var restyledBlockCount = 0
        /// The edit `shouldChangeTextIn` announced, consumed by the very next
        /// `textDidChange`. AppKit always pairs them, and anything that edits
        /// the storage WITHOUT the pair leaves the cache describing a stale
        /// string, which `applyStyles()` then repairs with a real parse.
        private var pendingEdit: (range: NSRange, replacementLength: Int)?

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

        // MARK: - Text

        /// Records WHERE the edit is about to happen, so `textDidChange` can
        /// shift the cached spans instead of re-parsing. Never vetoes an edit.
        ///
        /// A nil `replacementString` is an attributes-only change: there is no
        /// delta to shift by, so the cache is left to notice the mismatch.
        public func textView(_ tv: NSTextView, shouldChangeTextIn affected: NSRange,
                             replacementString: String?) -> Bool {
            // `tv.string` is still the PRE-edit text here, which is the only
            // moment the cache's currency can be checked against it. Spans that
            // did not describe the text before the edit cannot be shifted into
            // describing it after.
            pendingEdit = styleCache.describes(tv.string)
                ? replacementString.map { (affected, ($0 as NSString).length) }
                : nil
            return true
        }

        public func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            text.wrappedValue = tv.string
            if let edit = pendingEdit {
                styleCache.shift(editedRange: edit.range,
                                 delta: edit.replacementLength - edit.range.length,
                                 newText: tv.string)
            }
            pendingEdit = nil
            // Renders the SHIFTED spans — no parse on the keystroke path. The
            // real parse lands one debounce later.
            renderStyles()
            scheduleParse()
            // The ONE place `completions` is called: a keystroke happened.
            refreshCompletions()
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
            guard completionPanel.isVisible, let tv = textView else { return }
            if activePrefix(in: tv) == nil { completionPanel.hide() }
        }

        /// Focus left the editor. Nothing the list offers can be accepted from
        /// here, so it must not keep floating.
        public func textDidEndEditing(_ notification: Notification) {
            completionPanel.hide()
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

        private func refreshCompletions() {
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
