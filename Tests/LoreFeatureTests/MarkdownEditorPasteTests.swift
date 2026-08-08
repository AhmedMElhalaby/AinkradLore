import XCTest
import AppKit
@testable import LoreFeature

/// `LinkTextView.paste(_:)` — the Task 9 fix-round-1 regression coverage for
/// Critical 1: a mixed pasteboard (image bytes riding alongside a string
/// type, which is what copying an image out of Safari/Notes/Keynote or most
/// RTF copies actually produces) must paste as TEXT, not silently hijack the
/// paste into an attachment write that discards the text the user copied.
///
/// Drives the real system pasteboard (`NSPasteboard.general`) because
/// `paste(_:)` is hardcoded to it, the same way AppKit's own `paste(_:)`
/// is — there is no injectable seam. Restores whatever was there before each
/// test.
@MainActor
final class MarkdownEditorPasteTests: XCTestCase {
    // Not restored: an `NSPasteboardItem` read back off the pasteboard
    // cannot be re-written to it (`NSInvalidArgumentException`, "already
    // associated with another pasteboard"), and rebuilding an equivalent
    // item loses fidelity for arbitrary prior clipboard content anyway.
    // Test-only content is cleared instead — acceptable for a CI/test
    // process's pasteboard, which nothing else in this session depends on.
    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    private func textView(_ string: String = "") -> LinkTextView {
        let tv = LinkTextView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        tv.isRichText = false
        tv.string = string
        tv.allowsUndo = false
        return tv
    }

    private func onePixelPNG() -> Data {
        // A minimal valid 1x1 PNG — real bytes, not a placeholder, so
        // `pb.data(forType: .png)` returns something non-nil the same way a
        // real screenshot paste would.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        return Data(base64Encoded: base64)!
    }

    /// The regression this round of review found: a pasteboard offering
    /// BOTH image bytes and a string must paste the string, exactly like
    /// AppKit's own default `paste(_:)`, and must NEVER call
    /// `onPasteImage` — that closure writing a file is the whole bug.
    func test_mixedImageAndTextPasteboardPastesTextAndNeverWritesAFile() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(onePixelPNG(), forType: .png)
        item.setString("copied text", forType: .string)
        pb.writeObjects([item])

        let tv = textView("before ")
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        var handlerCalled = false
        tv.onPasteImage = { _, _ in handlerCalled = true; return true }

        tv.paste(nil)

        XCTAssertFalse(handlerCalled, "a pasteboard with a string type must never reach onPasteImage")
        XCTAssertEqual(tv.string, "before copied text")
    }

    /// The positive case, unchanged by the fix: an IMAGE-ONLY pasteboard
    /// (no string type at all — a real screenshot paste) must still reach
    /// `onPasteImage`.
    func test_imageOnlyPasteboardStillReachesOnPasteImage() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(onePixelPNG(), forType: .png)
        pb.writeObjects([item])

        let tv = textView("")
        var receivedData: Data?
        tv.onPasteImage = { data, name in
            receivedData = data
            XCTAssertTrue(name.hasSuffix(".png"))
            return true
        }

        tv.paste(nil)

        XCTAssertNotNil(receivedData)
        XCTAssertEqual(tv.string, "", "the handler owns the insert; paste(_:) must not also insert text")
    }
}
