import XCTest
import AppKit
@testable import LoreFeature

final class RichTextEngineTests: XCTestCase {
    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-rtf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func test_claimsRichTextExtensionsOnly() {
        for ext in ["docx", "rtf", "odt", "html", "htm", "DOCX"] {
            XCTAssertTrue(RichTextEngine.canOpen(URL(fileURLWithPath: "/x/a.\(ext)")), ext)
        }
        for ext in ["md", "txt", "pdf", "png"] {
            XCTAssertFalse(RichTextEngine.canOpen(URL(fileURLWithPath: "/x/a.\(ext)")), ext)
        }
    }

    func test_extractsPlainTextFromRTF() throws {
        let attributed = NSAttributedString(string: "Quarterly revenue summary")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = try tempFile("report.rtf", rtf)
        let engine = try RichTextEngine.load(url)
        XCTAssertTrue(engine.indexPayload.plaintext.contains("Quarterly revenue"))
        XCTAssertEqual(engine.indexTitle, "report")
        XCTAssertFalse(engine.isEditable)
    }

    func test_extractsPlainTextFromHTML() throws {
        let html = Data("<html><body><h1>Ainkrad</h1><p>Design notes</p></body></html>".utf8)
        let url = try tempFile("page.html", html)
        let engine = try RichTextEngine.load(url)
        XCTAssertTrue(engine.indexPayload.plaintext.contains("Design notes"))
    }

    func test_unparseableFile_loadsWithAFailureAndNoText() throws {
        let url = try tempFile("broken.docx", Data([0x00, 0x01, 0x02, 0x03]))
        let engine = try RichTextEngine.load(url)
        XCTAssertNotNil(engine.loadFailure)
        XCTAssertEqual(engine.indexPayload.plaintext, "")
        XCTAssertEqual(engine.indexTitle, "broken")
    }

    func test_save_throwsReadOnly() throws {
        let url = try tempFile("report.rtf", Data("{\\rtf1 hello}".utf8))
        let engine = try RichTextEngine.load(url)
        XCTAssertThrowsError(try engine.save(to: url)) { error in
            XCTAssertEqual(error as? EngineError, .readOnly(url))
        }
    }
}
