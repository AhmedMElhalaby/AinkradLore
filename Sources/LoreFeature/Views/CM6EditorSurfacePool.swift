import WebKit

/// Reusable CodeMirror surfaces, one per VISIBLE pane rather than one per open
/// note.
///
/// ## Why this is not an optimisation
///
/// Measured in the M10 spike, three panes on a real note:
///
///     native NSTextView ....  3.3 MB per pane, in process
///     WKWebView ............ 40.2 MB per view, in a WebContent process
///     empty page ........... 18.7 MB per view
///
/// So ~19 MB is WebKit's floor for a web view existing at all and ~21 MB is
/// CodeMirror plus the document. The cost is per WEB VIEW, not per note — which
/// means a surface per open note is not affordable and a surface per visible
/// pane is. Ten open notes in one pane must cost one surface, not ten, and that
/// is what this type is for.
///
/// Sharing one `WKWebViewConfiguration` was tried first, on the theory that
/// same-origin pages would share a content process. It made things WORSE (four
/// processes, 200 MB), so pooling the views themselves is the mitigation that
/// actually works.
///
/// ## Why the pool holds LOADED views
///
/// A fresh `WKWebView` has to load the bundle and boot CodeMirror before it can
/// show anything, which is the visible delay when opening a note. A pooled view
/// has already done both, so switching notes is one `setDocument` call. That
/// also means `didFinish` will NOT fire for a reused view — the borrower has to
/// be told it is already live, which is what `isPreloaded` is for.
@MainActor
final class CM6EditorSurfacePool {
    static let shared = CM6EditorSurfacePool()

    /// Views that have finished loading and are not in use.
    private var idle: [WKWebView] = []
    /// Diagnostics, so the "one surface per pane" claim is measurable rather
    /// than asserted. See `CM6SurfacePoolTests`.
    private(set) var created = 0
    private(set) var reused = 0

    /// How many idle surfaces to keep. One is the common case (a single pane);
    /// two covers a split without keeping a third alive for a layout nobody is
    /// looking at. Above this, a returned surface is released rather than kept:
    /// ~40 MB is too much to hold for a pane that may never come back.
    private let capacity = 2

    private init() {}

    /// A surface to render into, and whether it is already booted.
    ///
    /// The caller owns it until it calls `release`. Nothing here inspects or
    /// resets the page — the borrower knows what document it wants and says so.
    func acquire(configuring: (WKWebViewConfiguration) -> Void) -> (WKWebView, isPreloaded: Bool) {
        if let view = idle.popLast() {
            reused += 1
            return (view, true)
        }
        created += 1
        let config = WKWebViewConfiguration()
        configuring(config)
        return (WKWebView(frame: .zero, configuration: config), false)
    }

    /// Hand a surface back.
    ///
    /// The message handler is removed by NAME: a pooled view's
    /// `userContentController` outlives its borrower, and leaving the old
    /// coordinator installed both leaks it and delivers the next pane's edits
    /// to the previous pane's binding — which would look like edits landing in
    /// the wrong note.
    func release(_ view: WKWebView, handlerName: String) {
        view.configuration.userContentController
            .removeScriptMessageHandler(forName: handlerName)
        view.navigationDelegate = nil
        guard idle.count < capacity else { return }
        idle.append(view)
    }

    /// For tests only: forget everything, so one test's pool cannot decide
    /// another's assertions.
    func drainForTesting() {
        idle.removeAll()
        created = 0
        reused = 0
    }
}
