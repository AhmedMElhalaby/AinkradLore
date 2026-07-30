import SwiftUI
import AppKit
import AinkradAppKit

/// Floats `LinkCompletionView` over the editor without stealing focus.
///
/// A child `NSPanel`, not an `NSPopover`: a popover makes its own window key,
/// which pulls first-responder status off the text view and stops the very
/// typing the completion list exists to assist. A `.nonactivatingPanel` added
/// as a child window keeps the text view first responder, so every keystroke
/// still lands in the document. That in turn means the panel never receives
/// key events at all — arrow/return/escape handling lives in the text view's
/// `doCommandBy:` and drives this controller's selection.
@MainActor
final class LinkCompletionPanel {
    private var panel: NSPanel?
    private var host: NSHostingController<LinkCompletionView>?

    private(set) var matches: [IndexRow] = []
    private(set) var selected = 0

    /// Called when the user picks a row, by click or by return.
    var onPick: ((IndexRow) -> Void)?

    var isVisible: Bool { panel != nil }

    /// - Parameter caretRect: the caret rect in SCREEN coordinates, as returned
    ///   by `NSTextView.firstRect(forCharacterRange:actualRange:)`.
    func show(matches: [IndexRow], tokens: HostThemeTokens,
              caretRect: NSRect, over view: NSView) {
        guard !matches.isEmpty, let window = view.window else { hide(); return }
        if self.matches != matches { selected = 0 }
        self.matches = matches
        selected = min(selected, max(0, matches.count - 1))

        let root = makeRootView(tokens: tokens)
        let panel = self.panel ?? makePanel(attachedTo: window)
        if let host { host.rootView = root } else {
            let controller = NSHostingController(rootView: root)
            host = controller
            panel.contentViewController = controller
        }
        self.panel = panel

        let size = host?.view.fittingSize ?? NSSize(width: 260, height: 100)
        panel.setContentSize(size)
        // Below the caret line by default; above it when there is no room, so
        // the list never hangs off the bottom of the screen.
        let screen = window.screen ?? NSScreen.main
        let below = caretRect.minY - 4
        let fitsBelow = (screen.map { below - size.height >= $0.visibleFrame.minY }) ?? true
        let topLeft = NSPoint(x: caretRect.minX,
                              y: fitsBelow ? below : caretRect.maxY + 4 + size.height)
        panel.setFrameTopLeftPoint(topLeft)
        panel.orderFront(nil)
    }

    func hide() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        host = nil
        matches = []
        selected = 0
    }

    /// Arrow-key navigation. Clamped rather than wrapping: wrapping in a short
    /// list reads as the selection jumping unpredictably.
    func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let limit = min(matches.count, LinkCompletionView.maxRows) - 1
        selected = min(max(0, selected + delta), limit)
        if let host { host.rootView = rebuild(host.rootView) }
    }

    func pickSelected() {
        guard selected < matches.count else { return }
        onPick?(matches[selected])
    }

    private func makeRootView(tokens: HostThemeTokens) -> LinkCompletionView {
        LinkCompletionView(matches: matches, selected: selected, tokens: tokens) {
            [weak self] row in self?.onPick?(row)
        }
    }

    private func rebuild(_ old: LinkCompletionView) -> LinkCompletionView {
        makeRootView(tokens: old.tokens)
    }

    private func makePanel(attachedTo window: NSWindow) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        window.addChildWindow(panel, ordered: .above)
        return panel
    }
}
