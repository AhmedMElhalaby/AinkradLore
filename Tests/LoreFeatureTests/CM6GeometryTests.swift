import AppKit
import WebKit
import XCTest
@testable import LoreFeature

/// Clicking a line must select THAT line, and the caret must be visible.
///
/// Both were reported by the owner against a build that passed 1,619 tests:
/// "cursor is not showing and it's glitching, i try to select line it select
/// another". Neither was a rendering question, which is why every screenshot
/// looked right — a still image shows neither where a click lands nor a caret
/// that is one pixel wide and the same colour as the background.
///
/// Both causes were CSS this file's stylesheet introduced:
///
///  1. `drawSelection()` draws the caret itself, taking its colour from
///     CodeMirror's BASE theme — the light one, `solid black`. Every colour in
///     our stylesheet was for something we drew; nothing styled what CodeMirror
///     draws.
///  2. The heading rhythm used `margin` on `.cm-line`. CodeMirror measures line
///     heights to map a click to a position, its height oracle does not account
///     for margins, and adjacent margins collapse — so the drawn position and
///     the computed one diverge, cumulatively, down the document.
final class CM6GeometryTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var webView: WKWebView!
    override func tearDown() { windows.removeAll(); super.tearDown() }

    /// Headings, so the rules that broke this are exercised, interleaved with
    /// enough prose for an accumulating error to show.
    private static let document = """
    # Heading one

    A paragraph of prose after the first heading.

    ## Heading two

    More prose, and a second line of it so the block has height.

    ### Heading three

    - a bullet
    - another bullet

    #### Heading four

    A paragraph before a rule.

    ---

    | A | B |
    |---|---|
    | one | two |

    ##### Heading five

    $$\\frac{a}{b}$$

    ###### Heading six

    The last paragraph of the note.

    """

    @MainActor
    private func boot(_ text: String) throws {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1400))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = webView
        windows.append(window)
        // KEY, not merely on screen. `drawSelection()` draws the caret only for
        // a focused view, and a window that is never made key never gives the
        // web view first responder — so the caret element never exists and the
        // colour cannot be measured at all.
        window.makeKeyAndOrderFront(nil)
        webView.window?.makeFirstResponder(webView)
        let index = try XCTUnwrap(CM6EditorView.Coordinator.bundledIndexURL)
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        try waitFor("boot") {
            ((try? self.js("typeof window.loreEditor")) as? String) == "object"
        }
        _ = try js("window.loreEditor.init(\(CM6EditorView.Coordinator.jsString(text)))")
        _ = try js("window.loreEditor.focusEnd()")
    }

    // MARK: - a click lands where it looks

    /// THE assertion the whole suite was missing: for every line, the
    /// coordinates CodeMirror draws it at must map back to that same line.
    /// Lines inside a block widget — a table, a multi-line maths block, a
    /// transclusion — are excluded by the hook itself: they have no drawn
    /// position of their own, so mapping one to the widget's first line is
    /// correct. The first version of this test counted those as failures and
    /// reported the table's interior, which was not the bug.
    @MainActor
    func test_everyLineMapsBackToItself() throws {
        try boot(Self.document)
        let mismatched = try js("window.loreEditor.geometryMismatchedLines()") as? [Int] ?? [-1]
        XCTAssertEqual(mismatched, [],
                       "clicking these lines would select a different one")
    }

    /// And with the caret parked in the middle, since a reveal changes the
    /// height of the line it reveals.
    @MainActor
    func test_everyLineStillMapsBackWithTheCaretInsideTheDocument() throws {
        try boot(Self.document)
        _ = try js("""
        window.loreEditor.selectAt(window.loreEditor.text().indexOf('Heading three'))
        """)
        let mismatched = try js("window.loreEditor.geometryMismatchedLines()") as? [Int] ?? [-1]
        XCTAssertEqual(mismatched, [])
    }

    /// A plain document, as a control: if this ever fails the cause is not the
    /// decorations.
    @MainActor
    func test_aPlainDocumentMapsBackToo() throws {
        try boot("one\ntwo\nthree\nfour\nfive\n")
        XCTAssertEqual(try js("window.loreEditor.geometryMismatchedLines()") as? [Int], [])
    }

    // MARK: - the caret can be seen

    /// The caret CodeMirror draws must not be black.
    ///
    /// Asserted against the SHIPPED stylesheet rather than the live element,
    /// and that limit is worth stating: `drawSelection()` only draws a caret for
    /// a focused view, and a web view inside this test process never becomes
    /// first responder however the window is configured — the element simply
    /// does not exist here. The live values were measured in a standalone app
    /// instead, before and after the fix:
    ///
    ///     before ..  caret rgb(0, 0, 0)        page rgb(22, 22, 28)
    ///     after ...  caret rgb(230, 230, 234)  page rgb(22, 22, 28)
    ///     selection  color(srgb 0.49 0.42 0.94 / 0.38)
    ///
    /// So this test is a regression guard on the declaration, not a measurement
    /// of the pixels. It would have caught the original bug, which was the
    /// absence of any caret rule at all.
    func test_theStylesheetGivesTheCaretTheHostsForegroundColour() throws {
        let css = try String(contentsOf: XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "index", withExtension: "html")), encoding: .utf8)
        let rules = Self.rules(for: "cm-cursor", in: css)
        XCTAssertFalse(rules.isEmpty,
                       "nothing styles the caret, so CodeMirror's light base "
                       + "theme draws it black on whatever the page is")
        let joined = rules.joined()
        XCTAssertTrue(joined.contains("var(--fg)"),
                      "the caret must take the HOST's foreground, not a constant: \(joined)")
        // CodeMirror's rule is `&light .cm-cursor`, a two-class descendant
        // selector, so an unqualified override loses to it — measured.
        XCTAssertTrue(joined.contains("!important"),
                      "the override has to outrank CodeMirror's own rule")
    }

    /// And the selection, for the same reason: CodeMirror's light base theme
    /// draws a pale grey block, which on a dark page hides the text it covers.
    func test_theStylesheetGivesTheSelectionTheAccentColour() throws {
        let css = try String(contentsOf: XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "index", withExtension: "html")), encoding: .utf8)
        let joined = Self.rules(for: "cm-selectionBackground", in: css).joined()
        XCTAssertTrue(joined.contains("--accent-primary"), "got \(joined)")
        XCTAssertTrue(joined.contains("!important"), "got \(joined)")
    }

    /// Nothing in this stylesheet may put `margin` on a line or on a block
    /// widget again. Asserted against the shipped CSS, because the failure is
    /// invisible in every screenshot and only shows as a mis-aimed click.
    func test_theStylesheetPutsNoMarginOnAnythingCodeMirrorMeasures() throws {
        let css = try String(contentsOf: XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "index", withExtension: "html")), encoding: .utf8)
        // Line-level and block-widget classes, in the order they appear.
        let measured = ["cm-lore-h1", "cm-lore-h2", "cm-lore-h3", "cm-lore-h4",
                        "cm-lore-h5", "cm-lore-h6", "cm-lore-math-block",
                        "cm-lore-transclusion", "cm-lore-rule",
                        "cm-lore-code", "cm-lore-callout"]
        for name in measured {
            for rule in Self.rules(for: name, in: css) {
                XCTAssertFalse(Self.setsVerticalMargin(rule),
                               "\(name) sets a vertical margin: \(rule)")
            }
        }
    }

    /// The declaration blocks of any rule whose selector mentions `name`.
    private static func rules(for name: String, in css: String) -> [String] {
        var found: [String] = []
        var rest = Substring(css)
        while let hit = rest.range(of: "." + name) {
            // Only a whole class name, not a prefix of a longer one.
            let after = rest[hit.upperBound...].first
            guard after == nil || !(after!.isLetter || after!.isNumber || after! == "-")
            else { rest = rest[hit.upperBound...]; continue }
            guard let open = rest[hit.upperBound...].firstIndex(of: "{"),
                  let close = rest[open...].firstIndex(of: "}") else { break }
            found.append(String(rest[open...close]))
            rest = rest[close...]
        }
        return found
    }

    private static func setsVerticalMargin(_ block: String) -> Bool {
        for declaration in block.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(
                in: CharacterSet(charactersIn: "{} \n\t"))
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "} \n\t"))
            switch property {
            case "margin-top", "margin-bottom":
                if value != "0" { return true }
            case "margin":
                // `margin: 0` is fine; anything with a non-zero vertical
                // component is not. One value or three-plus means top and
                // bottom are set; two means the first is vertical.
                let values = value.split(separator: " ").map(String.init)
                let vertical = values.count == 1 ? [values[0]]
                    : values.count == 2 ? [values[0]]
                    : [values[0], values.count > 2 ? values[2] : values[0]]
                if vertical.contains(where: { $0 != "0" }) { return true }
            default: continue
            }
        }
        return false
    }

    // MARK: - plumbing

    @MainActor @discardableResult
    private func js(_ source: String) throws -> Any? {
        var result: Any?; var failure: Error?; var done = false
        webView.evaluateJavaScript(source) { v, e in result = v; failure = e; done = true }
        let deadline = Date().addingTimeInterval(20)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let failure { throw failure }
        return result
    }

    @MainActor
    private func waitFor(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
