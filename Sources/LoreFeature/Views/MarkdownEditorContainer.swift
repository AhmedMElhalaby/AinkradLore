import AppKit

/// The scroll view's document view: the text view, and an optional accessory
/// band beneath it that scrolls with the document.
///
/// ## Why the text view stopped being the document view
///
/// Linked mentions belong BELOW the document body — that is where you look
/// when you have finished reading, and it is the one place a list of "what
/// else points here" costs nothing while you are writing, because you never
/// scroll past the end mid-sentence.
///
/// `NSTextView` has no bottom-only inset to host that in. `textContainerInset`
/// is an `NSSize` applied symmetrically, so reserving 200pt below the text
/// also reserves 200pt above it. And a SwiftUI sibling in a `VStack` would sit
/// outside the scroll view, pinned to the pane instead of trailing the text —
/// which is a panel again, just at the bottom.
///
/// So the document view becomes this container, and the text view becomes its
/// child. The text view still sizes itself to its content (`isVerticallyResizable`
/// is untouched); this view watches that and keeps the accessory directly
/// beneath it.
///
/// ## Flipped
///
/// AppKit's default coordinate system puts the origin at the BOTTOM, so
/// stacking two views top-to-bottom means computing every frame from the
/// container's total height — which changes on every keystroke. Flipped, the
/// text view sits at `y == 0` and the accessory at `y == textHeight`, and
/// neither needs to know how tall the whole thing is.
final class MarkdownEditorContainerView: NSView {
    override var isFlipped: Bool { true }

    /// The text view. Always present.
    private(set) weak var textView: NSView?
    /// The accessory beneath it, if any.
    private(set) var accessory: NSView?

    func install(textView: NSView) {
        self.textView = textView
        addSubview(textView)
    }

    /// Puts `view` below the text, replacing any previous accessory.
    ///
    /// Replacing rather than accumulating: this is called whenever the footer's
    /// CONTENT changes (a new document, a new backlink count), and an
    /// accumulate-only version would stack every version of the footer the
    /// document has ever had, invisibly, one behind the other.
    func setAccessory(_ view: NSView?) {
        guard accessory !== view else { return }
        accessory?.removeFromSuperview()
        accessory = view
        if let view { addSubview(view) }
        layoutContents()
    }

    /// Positions the text and the accessory, and sizes self to fit both.
    ///
    /// Height is driven by the TEXT VIEW's own frame, which AppKit already
    /// keeps equal to the laid-out text — so this never measures text itself
    /// and never forces layout. That is what keeps it off the typing hot path:
    /// the text view resizes, this repositions one subview and updates its own
    /// height, and nothing re-lays-out the document.
    func layoutContents() {
        guard let textView else { return }
        let width = bounds.width
        var textFrame = textView.frame
        textFrame.origin = .zero
        textFrame.size.width = width
        textView.frame = textFrame

        var total = textFrame.height
        if let accessory {
            let height = accessory.fittingSize.height
            accessory.frame = NSRect(x: 0, y: total, width: width, height: height)
            total += height
        }
        if abs(frame.height - total) > 0.5 || abs(frame.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: total))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Width changes come from the clip view (a window resize); the text
        // view has to follow before it re-wraps.
        if let textView, abs(textView.frame.width - newSize.width) > 0.5 {
            layoutContents()
        }
    }
}
