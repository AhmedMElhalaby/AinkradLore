import SwiftUI
import PDFKit
import AinkradAppKit

/// PDFs: viewable and full-text searchable, never editable.
///
/// A corrupt or password-protected PDF is NOT a load error. The failure rule
/// for this milestone is that an unreadable document still indexes by filename
/// and still opens — so `load` always succeeds and records why the content is
/// missing in `loadFailure`, which the viewer renders. Throwing here would put
/// the file back in the dead-end state `AttachmentEngine` exists to abolish.
public final class PDFEngine: DocumentEngine {
    public static let identifier = "pdf"

    public private(set) var sourceURL: URL
    public private(set) var extractedText: String
    /// Human-readable reason the content could not be read, or nil.
    public private(set) var loadFailure: String?
    /// The `Title` from the PDF's document attributes, when it has a non-empty
    /// one. Many PDFs carry a generator's junk title, so the filename wins
    /// unless this is present AND non-blank.
    public private(set) var metadataTitle: String?

    private init(sourceURL: URL, extractedText: String,
                 loadFailure: String?, metadataTitle: String?) {
        self.sourceURL = sourceURL
        self.extractedText = extractedText
        self.loadFailure = loadFailure
        self.metadataTitle = metadataTitle
    }

    public static func canOpen(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    public static func load(_ url: URL) throws -> PDFEngine {
        guard let document = PDFDocument(url: url) else {
            return PDFEngine(sourceURL: url, extractedText: "",
                             loadFailure: "This PDF could not be read. It may be damaged.",
                             metadataTitle: nil)
        }
        if document.isLocked {
            return PDFEngine(sourceURL: url, extractedText: "",
                             loadFailure: "This PDF is password-protected.",
                             metadataTitle: nil)
        }
        // `document.string` concatenates every page. Capped at the index limit
        // here rather than downstream so a 900-page scan never holds its whole
        // text resident during a vault rescan.
        let text = VaultIndexCoordinator.capped(document.string ?? "")
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PDFEngine(sourceURL: url, extractedText: text, loadFailure: nil,
                         metadataTitle: (title?.isEmpty == false) ? title : nil)
    }

    public func save(to url: URL) throws {
        throw EngineError.readOnly(url)
    }

    public var isEditable: Bool { false }

    public func replaceContents(with other: PDFEngine) {
        sourceURL = other.sourceURL
        extractedText = other.extractedText
        loadFailure = other.loadFailure
        metadataTitle = other.metadataTitle
    }

    public var indexTitle: String {
        metadataTitle ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    public var indexPayload: IndexPayload {
        IndexPayload(title: indexTitle, plaintext: extractedText)
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        if let loadFailure {
            return AnyView(DocumentErrorCard(url: sourceURL, message: loadFailure,
                                             theme: ctx.theme))
        }
        return AnyView(PDFViewer(url: sourceURL).background(ctx.theme.tokens.background))
    }
}

@MainActor
private struct PDFViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
