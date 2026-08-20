import SwiftUI
import WebKit
import AinkradAppKit

/// The CodeMirror editor surface.
///
/// ## Why this exists
///
/// See `2026-08-19-lore-obsidian-parity-architecture-design`. The native
/// renderer can style text and paint pictures over collapsed source; it cannot
/// put a caret inside a rendered element, which is what Obsidian's tables,
/// embeds and callouts all rest on. CodeMirror replaces a source range with
/// real content, so the caret has somewhere to go.
///
/// ## Who owns the document
///
/// **Swift does.** `text` is the source of truth; CM6 holds a copy and reports
/// what the user did to it. Two rules follow, and both are load-bearing:
///
/// 1. A change that came FROM Swift is never reported back to Swift (see
///    `applyingFromSwift` in `editor.js`). Otherwise the two push at each other
///    and drop keystrokes under a fast typist — silently, only under load.
/// 2. Swift never pushes text it has just been told about. `lastFromEditor`
///    is what makes an ordinary keystroke cost one message instead of two and
///    a caret reset.
///
/// Nothing here transforms the text. Not line endings, not normalisation,
/// nothing: this surface is a VIEW of the document, and a view that quietly
/// rewrites what it shows is how a vault gets corrupted one save at a time.
struct CM6EditorView: NSViewRepresentable {
    @Binding var text: String
    let tokens: HostThemeTokens
    let settings: EditorSettings

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        // Pooled, not created — see `CM6EditorSurfacePool`. A surface costs
        // ~40 MB, so switching notes must reuse one rather than open another.
        let (webView, isPreloaded) = CM6EditorSurfacePool.shared.acquire { config in
            config.userContentController.add(coordinator, name: Coordinator.bridgeName)
        }
        if isPreloaded {
            // A reused surface already has the handler of whoever had it last
            // removed by `release`, so this one has to be installed now.
            webView.configuration.userContentController.add(coordinator,
                                                            name: Coordinator.bridgeName)
        }
        webView.navigationDelegate = coordinator
        // No bounce, no zoom: this is a text editor, not a web page.
        webView.setValue(false, forKey: "drawsBackground")
        coordinator.webView = webView
        coordinator.pendingDocument = text
        coordinator.pendingTheme = (tokens, settings)

        if isPreloaded {
            // `didFinish` will NOT fire again for a page that is already
            // loaded, so the boot that normally happens there happens here.
            coordinator.adoptPreloadedSurface()
            return webView
        }
        guard let index = Coordinator.bundledIndexURL else {
            assertionFailure("Editor/dist is missing from the plugin bundle")
            return webView
        }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        return webView
    }

    /// Hand the surface back when the pane goes away, rather than letting a
    /// ~40 MB web view be deallocated and rebuilt for the next note.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.webView = nil
        CM6EditorSurfacePool.shared.release(webView, handlerName: Coordinator.bridgeName)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.push(document: text)
        context.coordinator.push(tokens: tokens, settings: settings)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let bridgeName = "lore"

        /// `Editor/dist/index.html`, copied into the plugin's Resources by the
        /// build. `Bundle(for:)` rather than `.main`: `.main` is the HOST app,
        /// and this is a plugin bundle.
        static var bundledIndexURL: URL? {
            Bundle(for: Coordinator.self).url(forResource: "index", withExtension: "html")
        }

        private let text: Binding<String>
        var webView: WKWebView?
        /// Set before the page has loaded; applied on `didFinish`.
        var pendingDocument: String?
        var pendingTheme: (HostThemeTokens, EditorSettings)?
        private var isLoaded = false

        /// The last text the EDITOR told us about.
        ///
        /// Rule 2 above. Without it, every keystroke round-trips: CM6 reports,
        /// SwiftUI re-renders, `updateNSView` pushes the same string back, and
        /// the caret is reset mid-word.
        private var lastFromEditor: String?

        /// The line ending this document arrived with. CodeMirror normalises
        /// to LF and cannot be talked out of it, so the ending is recorded on
        /// the way in and restored on the way out — see `CM6LineEndings`.
        private var ending: CM6LineEndings.Ending = .lf

        init(text: Binding<String>) {
            self.text = text
            super.init()
        }

        // MARK: - Swift to the editor

        func push(document: String) {
            guard isLoaded else { pendingDocument = document; return }
            // Already came from there; pushing it back is the loop.
            if document == lastFromEditor { return }
            ending = CM6LineEndings.dominant(in: document)
            if !CM6LineEndings.isConsistent(document) {
                // Declared, not hidden: this note's bytes are about to change.
                NSLog("Lore: mixed line endings normalised to \(ending) on open")
            }
            evaluate("window.loreEditor.setDocument("
                     + Self.jsString(CM6LineEndings.toLF(document)) + ")")
        }

        func push(tokens: HostThemeTokens, settings: EditorSettings) {
            guard isLoaded else { pendingTheme = (tokens, settings); return }
            let theme = MarkdownTheme(tokens: tokens, settings: settings)
            // Colour stays the host's, scale stays Lore's — the same division
            // `MarkdownTheme` already encodes for the native renderer.
            let css: [String: String] = [
                "--bg": Self.css(tokens.background),
                "--fg": Self.css(tokens.foreground),
                "--accent-primary": Self.css(tokens.accentPrimary),
                "--surface-elevated": Self.css(tokens.surfaceElevated),
                "--text-faint": Self.css(tokens.foreground, alpha: 0.4),
                "--body-size": "\(theme.bodyFont.pointSize)px",
                "--line-height": "\(theme.lineHeightMultiple)",
            ]
            let assignments = css.map {
                "d.style.setProperty('\($0.key)', '\($0.value)');"
            }.joined()
            evaluate("(() => { const d = document.documentElement; \(assignments) })()")
        }

        private func evaluate(_ source: String) {
            webView?.evaluateJavaScript(source) { _, error in
                if let error { NSLog("CM6 bridge: \(error)") }
            }
        }

        // MARK: - The editor to Swift

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  body["kind"] as? String == "doc",
                  let reported = body["text"] as? String else { return }
            // CM6 speaks LF; the document speaks whatever it arrived with.
            let incoming = CM6LineEndings.from(reported, to: ending)
            lastFromEditor = incoming
            // Only when it really differs: SwiftUI bindings are not free, and
            // an identical write still invalidates the view.
            if text.wrappedValue != incoming { text.wrappedValue = incoming }
        }

        /// The boot path for a POOLED surface, whose page is already loaded and
        /// whose `didFinish` therefore never fires again.
        func adoptPreloadedSurface() {
            // Deliberately routed through the same code the fresh path uses,
            // so the two cannot drift: a reused surface that initialised
            // slightly differently from a new one is a bug that only appears
            // on the second note opened.
            finishLoading()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finishLoading()
        }

        private func finishLoading() {
            isLoaded = true
            if let document = pendingDocument {
                ending = CM6LineEndings.dominant(in: document)
                evaluate("window.loreEditor.init("
                         + Self.jsString(CM6LineEndings.toLF(document)) + ")")
                pendingDocument = nil
            }
            if let (tokens, settings) = pendingTheme {
                push(tokens: tokens, settings: settings)
                pendingTheme = nil
            }
        }

        // MARK: - Encoding

        /// A JS string literal for `value`, via `JSONSerialization`.
        ///
        /// NOT hand-escaped. The document can hold quotes, backslashes,
        /// newlines, emoji, lone surrogates and U+2028, and every one of those
        /// is a way to end up injecting or truncating. This is the single place
        /// text crosses into JavaScript, so it is the single place that has to
        /// be right.
        ///
        /// `nonisolated` because it touches nothing but its argument, and the
        /// tests that pin the escaping have no business spinning up a main
        /// actor to check that a backslash comes out escaped.
        nonisolated static func jsString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let array = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(array.dropFirst().dropLast())
        }

        static func css(_ color: Color, alpha: Double = 1) -> String {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .textColor
            let r = Int((ns.redComponent * 255).rounded())
            let g = Int((ns.greenComponent * 255).rounded())
            let b = Int((ns.blueComponent * 255).rounded())
            return alpha >= 1 ? "rgb(\(r), \(g), \(b))"
                              : "rgba(\(r), \(g), \(b), \(alpha))"
        }
    }
}
