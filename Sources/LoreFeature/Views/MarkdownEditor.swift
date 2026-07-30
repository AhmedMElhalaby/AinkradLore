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

    public init(text: Binding<String>, tokens: HostThemeTokens,
                completions: (@MainActor (String) -> [IndexRow])? = nil,
                onOpenLink: (@MainActor (String) -> Void)? = nil) {
        self._text = text; self.tokens = tokens
        self.completions = completions; self.onOpenLink = onOpenLink
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
        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(tokens.background)
        tv.insertionPointColor = NSColor(tokens.accentPrimary)
        tv.textContainerInset = NSSize(width: 16, height: 16)
        tv.onCommandClick = { [weak coordinator = context.coordinator] index in
            coordinator?.openLink(atUTF16: index) ?? false
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
        tv.string = text
        context.coordinator.applyStyles()
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.completions = completions
        context.coordinator.onOpenLink = onOpenLink
        if tv.string != text { tv.string = text; context.coordinator.applyStyles() }
        tv.backgroundColor = NSColor(tokens.background)
        tv.insertionPointColor = NSColor(tokens.accentPrimary)
        context.coordinator.tokens = tokens
        context.coordinator.applyStyles()
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
        weak var textView: NSTextView?
        let completionPanel = LinkCompletionPanel()
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
                    MainActor.assumeIsolated { self?.repositionCompletions() }
                }
        }

        func tearDown() {
            completionPanel.hide()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
        }

        // MARK: - Text

        public func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            text.wrappedValue = tv.string
            applyStyles()
            // The ONE place `completions` is called: a keystroke happened.
            refreshCompletions()
        }

        /// Caret moved without the text changing (click, arrow key). Cheap and
        /// index-free: it can only ever dismiss, never open, so it never asks
        /// the store for rows.
        public func textViewDidChangeSelection(_ notification: Notification) {
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
            guard completionPanel.isVisible else { return false }
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
            let insertion = LinkCompletionContext.insertableTarget(for: row) + "]]"
            let caretUTF16 = tv.selectedRange().location
            let range = NSRange(location: caretUTF16 - prefix.utf16.count,
                                length: prefix.utf16.count)
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

        // MARK: - Styling

        func applyStyles() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor(tokens.foreground)
            ], range: full)
            for span in MarkdownStyler.spans(in: tv.string) {
                let r = NSRange(location: span.range.lowerBound, length: span.range.count)
                switch span.kind {
                case .heading(let lvl):
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(
                        ofSize: max(14, 26 - CGFloat(lvl) * 2)), range: r)
                    storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)
                case .bold:
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: r)
                case .italic:
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(
                        .systemFont(ofSize: 14), toHaveTrait: .italicFontMask), range: r)
                case .code:
                    storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentSecondary), range: r)
                case .link:
                    storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                case .checkbox:
                    storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentTertiary), range: r)
                }
            }
            storage.endEditing()
        }
    }
}

/// `NSTextView` that reports Cmd-clicks.
///
/// Cmd-click, not a plain click: inside an editor the primary meaning of a
/// click is "put the caret here". Hijacking a plain click on a `[[…]]` span
/// would make the link text the one run of characters in the document the user
/// cannot click into to fix a typo. Cmd-click is also what every other
/// editor-with-links on this platform uses, and it leaves the pointer's normal
/// behaviour — selection, drag, double-click-to-word — completely intact.
final class LinkTextView: NSTextView {
    /// Receives the clicked UTF-16 offset and reports whether it opened a link.
    /// The Bool matters: a Cmd-click that hits no link — or a document with no
    /// link handler at all, i.e. plain text — must fall through to AppKit so
    /// the caret still lands where the user clicked.
    var onCommandClick: (@MainActor (Int) -> Bool)?
    /// Fires whenever focus leaves this view, including the routes that do not
    /// produce a `textDidEndEditing`.
    var onResignFirstResponder: (@MainActor () -> Void)?

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFirstResponder?() }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onCommandClick else {
            super.mouseDown(with: event); return
        }
        let point = convert(event.locationInWindow, from: nil)
        if !onCommandClick(characterIndexForInsertion(at: point)) {
            super.mouseDown(with: event)
        }
    }
}
