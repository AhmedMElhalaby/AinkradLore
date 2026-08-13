import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

/// Task 10, Part 2: does `updateNSView` actually run per keystroke?
///
/// The Task 10 measurement report established by READING that
/// `MarkdownEditor.updateNSView` calls `applyStyles()` unconditionally, and
/// therefore that a keystroke — which writes `text.wrappedValue` and so
/// invalidates the SwiftUI view — pays for a second full render. Reading can
/// establish what the code does when it runs; it cannot establish that SwiftUI
/// schedules it per keystroke rather than coalescing. That is a claim about a
/// framework's behaviour, so it is measured here against a REAL hosted view
/// hierarchy — `NSHostingView` in a window — rather than the detached
/// `NSTextView` the benchmarks use, because a detached view has no SwiftUI
/// above it and could never show this either way.
///
/// The counters (`applyStylesCalls`, `applyStylesRenders`) live on the
/// coordinator for the same reason `revealIndexBuilds` does: an O(1) claim is
/// only a claim until something counts.
@MainActor
final class MarkdownEditorRedrawTests: XCTestCase {

    /// A minimal host: exactly the ownership shape `DocumentPane` has — state
    /// above, binding into the editor — and nothing else, so what is measured
    /// is the editor's own redraw and not a pane's other subscriptions.
    private struct Host: View {
        @State var text: String
        var body: some View {
            MarkdownEditor(text: $text, tokens: TestTokens.make())
        }
    }

    /// Hosts `Host` in a real (offscreen) window and returns the editor's text
    /// view together with the coordinator SwiftUI built for it.
    ///
    /// The coordinator is reached through `tv.delegate` rather than through
    /// SwiftUI, which does not expose it: the delegate IS the coordinator, set
    /// in `makeNSView`.
    private func hostEditor(_ text: String) throws
        -> (MarkdownEditor.Coordinator, NSTextView, NSWindow, NSHostingView<Host>) {
        let hosting = NSHostingView(rootView: Host(text: text))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        pump()
        let tv = try XCTUnwrap(Self.firstTextView(in: hosting),
                              "the hosted editor must have produced an NSTextView")
        let coordinator = try XCTUnwrap(tv.delegate as? MarkdownEditor.Coordinator,
                                       "the text view's delegate must be the coordinator")
        return (coordinator, tv, window, hosting)
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }

    /// Lets SwiftUI's scheduled update actually run. A SwiftUI invalidation is
    /// applied on a later run-loop turn, so counting immediately after
    /// `insertText` would measure nothing and wrongly clear `updateNSView`.
    private func pump(_ seconds: TimeInterval = 0.35) {
        let landed = expectation(description: "run loop pumped")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { landed.fulfill() }
        wait(for: [landed], timeout: seconds + 2)
    }

    /// THE measurement Part 2 rests on. Recorded as a number in the report
    /// whichever way it comes out — a guard aimed at a render that does not
    /// happen would be worse than no guard.
    func test_measure_applyStylesCallsPerKeystrokeInAHostedEditor() throws {
        let body = MarkdownTypingLagBenchmark.fixture(lines: 200)
        let (coordinator, tv, window, hosting) = try hostEditor(body)
        try withExtendedLifetime((window, hosting)) {
            pump(0.6)                                   // open parse lands
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length / 2,
                                        length: 0))
            let callsBefore = coordinator.applyStylesCalls
            let rendersBefore = coordinator.revealIndexBuilds

            for _ in 0..<10 {
                tv.insertText("x", replacementRange: tv.selectedRange())
                pump(0.02)                              // let SwiftUI run
            }
            pump(0.3)

            let calls = Double(coordinator.applyStylesCalls - callsBefore) / 10
            let renders = Double(coordinator.revealIndexBuilds - rendersBefore) / 10
            print("REDRAW applyStyles-per-keystroke=\(calls) "
                  + "full-renders-per-keystroke=\(renders)")
            XCTAssertGreaterThan((tv.string as NSString).length,
                                 (body as NSString).length,
                                 "the keystrokes must have actually landed")
        }
    }

    /// The guard's own contract, once it exists: `applyStyles()` on text the
    /// cache already describes, with unchanged tokens, must not re-render.
    ///
    /// Asserted on the coordinator directly rather than through SwiftUI, so it
    /// pins the GUARD rather than the framework's scheduling.
    func test_applyStylesOnUnchangedTextAndTokensDoesNotRender() throws {
        let (coordinator, _, window, hosting) = try hostEditor("# Title\n\nSome **bold**.\n")
        try withExtendedLifetime((window, hosting)) {
            pump(0.6)
            let before = coordinator.revealIndexBuilds
            for _ in 0..<10 { coordinator.applyStyles() }
            XCTAssertEqual(coordinator.revealIndexBuilds, before,
                           "a redundant redraw must cost zero full renders")
        }
    }

    /// …and the guard must not swallow a redraw that MATTERS. A theme change
    /// alters every colour and font the attributes carry, so it must still
    /// re-render even though the text is unchanged.
    func test_aTokenChangeStillRenders() throws {
        let (coordinator, _, window, hosting) = try hostEditor("# Title\n")
        try withExtendedLifetime((window, hosting)) {
            pump(0.6)
            coordinator.applyStyles()
            let before = coordinator.revealIndexBuilds
            coordinator.tokens = HostThemeTokens(
                themeID: "other", background: .white, surface: .gray,
                surfaceElevated: .gray, accentPrimary: .red, accentSecondary: .orange,
                accentTertiary: .yellow, foreground: .black)
            coordinator.applyStyles()
            XCTAssertEqual(coordinator.revealIndexBuilds, before + 1,
                           "a theme change must still re-render")
        }
    }

    /// And text arriving from outside must still render, guard or no guard.
    func test_changedTextStillRenders() throws {
        let (coordinator, tv, window, hosting) = try hostEditor("# Title\n")
        try withExtendedLifetime((window, hosting)) {
            pump(0.6)
            coordinator.applyStyles()
            let before = coordinator.revealIndexBuilds
            tv.string = "# Something Else\n\n**bold**\n"
            coordinator.applyStyles()
            XCTAssertGreaterThan(coordinator.revealIndexBuilds, before,
                                 "externally replaced text must re-render")
        }
    }
}
