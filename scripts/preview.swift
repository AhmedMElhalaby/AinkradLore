// Mount the CodeMirror surface on a real note, so it can be looked at.
//
//   swiftc -O scripts/preview.swift -o scripts/.preview && ./scripts/.preview "<path>"
//
// The sibling of `shoot.sh` for the CM6 surface. The settings flag lives in the
// host's key-value store and cannot be flipped from outside the app, so this
// exists to make the surface visible without waiting on E4 or asking someone to
// toggle a preference before every screenshot.
//
// It loads the SHIPPED bundle — Editor/dist — not a copy, so what is on screen
// is what the plugin contains.
import AppKit
import WebKit

final class Delegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var document = "# No note given\n\nPass a path as the first argument.\n"

    func applicationDidFinishLaunching(_ note: Notification) {
        if CommandLine.arguments.count > 1,
           let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) {
            // Body only: the editor is bound to `note.body`, so previewing the
            // frontmatter would be previewing something the editor never sees.
            document = Self.body(of: text)
        }
        let dist = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Editor/dist")

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame,
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Lore — CodeMirror surface"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.loadFileURL(dist.appendingPathComponent("index.html"),
                            allowingReadAccessTo: dist)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: [document]),
                          encoding: .utf8)!
        let arg = String(json.dropFirst().dropLast())
        webView.evaluateJavaScript("window.loreEditor.init(\(arg))")
    }

    /// The same split `Frontmatter.parse` performs, kept deliberately dumb: a
    /// preview tool has no business importing the parser and no business being
    /// trusted about edge cases.
    static func body(of text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines[(close + 1)...].joined(separator: "\n")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
