import SwiftUI
import AppKit
import AinkradAppKit

// The `NSViewRepresentable` lifecycle for `MarkdownEditor` — building the
// `NSScrollView`/`LinkTextView` pair, wiring their callbacks to the
// `Coordinator`, and tearing them down. Moved out of `MarkdownEditor.swift`
// to keep that file to the type's declared surface (properties, init,
// `Coordinator`); this file is the AppKit object graph those properties
// describe.
extension MarkdownEditor {
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
        // The system find bar. `usesFindBar` puts it inside the scroll view
        // rather than in a floating panel, which is what keeps it attached to
        // the document it is searching when several are open.
        //
        // Safe alongside the markdown styling passes: find highlighting is
        // drawn with the layout manager's TEMPORARY attributes, while
        // `MarkdownStyleRendering` writes real attributes into the text
        // storage. The two never touch the same storage, so a restyle on the
        // next keystroke cannot erase the highlights — which is precisely the
        // collision that would have made this unusable.
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(tokens.background)
        tv.insertionPointColor = NSColor(tokens.accentPrimary)
        // Margins and measure come from the theme, and are both a function of
        // the view's width — see `MarkdownEditorLayout`. Set once here for the
        // initial size, then kept in sync by `onWidthChange` via
        // `applyContainerGeometry`, which owns both together so they cannot
        // drift apart on resize.
        let initialTheme = MarkdownTheme(tokens: tokens, settings: settings)
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
        // The document view is a CONTAINER, not the text view itself — see
        // `MarkdownEditorContainerView` for why (there is no bottom-only inset
        // on NSTextView to host the linked-mentions footer in). The text view
        // keeps sizing itself to its content exactly as before; the container
        // only follows it.
        let container = MarkdownEditorContainerView(
            frame: NSRect(x: 0, y: 0, width: tv.bounds.width, height: tv.bounds.height))
        container.autoresizingMask = [.width]
        container.install(textView: tv)
        scroll.documentView = container
        context.coordinator.container = container
        // The text view resizes itself as the document grows; the container has
        // to follow so the footer stays directly beneath the last line.
        tv.onHeightChange = { [weak container] in container?.layoutContents() }
        installFooterIfNeeded(context.coordinator, container: container)

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
        installFooterIfNeeded(context.coordinator, container: context.coordinator.container)
        context.coordinator.tokens = tokens
        // Display settings changing must re-lay out the document the reader is
        // ALREADY looking at — a font size that only applies to the next
        // document opened reads as a broken setting. The geometry is
        // re-applied explicitly because container inset and width are a
        // function of the theme AND the view width, and `applyStyles` alone
        // does not touch them (see `applyContainerGeometry`, which owns both
        // together so they cannot drift apart).
        if context.coordinator.settings != settings {
            context.coordinator.settings = settings
            context.coordinator.applyContainerGeometry(forWidth: tv.bounds.width)
        }
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

    /// Creates or refreshes the footer hosting view.
    ///
    /// Gated on `footerRevision` so an ancestor redraw does not re-render the
    /// footer's SwiftUI tree — see `MarkdownEditor.footerRevision`.
    private func installFooterIfNeeded(_ coordinator: Coordinator,
                                       container: MarkdownEditorContainerView?) {
        guard let container else { return }
        guard let footer else {
            coordinator.footerHost = nil
            coordinator.renderedFooterRevision = -1
            container.setAccessory(nil)
            return
        }
        if let host = coordinator.footerHost {
            guard coordinator.renderedFooterRevision != footerRevision else { return }
            host.rootView = footer
            coordinator.renderedFooterRevision = footerRevision
            container.layoutContents()
            return
        }
        let host = NSHostingView(rootView: footer)
        coordinator.footerHost = host
        coordinator.renderedFooterRevision = footerRevision
        container.setAccessory(host)
    }

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
}
