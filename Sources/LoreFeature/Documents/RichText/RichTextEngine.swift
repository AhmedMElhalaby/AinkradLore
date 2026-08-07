import SwiftUI
import AppKit
import AinkradAppKit

/// Word processor and markup formats, read-only.
///
/// AppKit reads `.docx`, `.rtf`, `.rtfd`, `.odt` and HTML natively through
/// `NSAttributedString(url:options:documentAttributes:)`. That is the entire
/// reason this engine can exist without adding a third-party parser to the
/// dependency graph — and why fidelity is "good enough to read", which is all a
/// read-only citizen owes. Editing these formats is explicitly out of scope;
/// converting them to markdown is M4's job, not this engine's.
public final class RichTextEngine: DocumentEngine {
    public static let identifier = "richtext"

    public static let extensions: Set<String> = ["docx", "rtf", "rtfd", "odt", "html", "htm"]

    public private(set) var sourceURL: URL
    public private(set) var attributed: NSAttributedString
    public private(set) var loadFailure: String?

    private init(sourceURL: URL, attributed: NSAttributedString, loadFailure: String?) {
        self.sourceURL = sourceURL
        self.attributed = attributed
        self.loadFailure = loadFailure
    }

    public static func canOpen(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Never throws, for the same reason `PDFEngine.load` never throws: an
    /// unreadable document must still index by filename and still open.
    ///
    /// AppKit's readers are notoriously permissive: garbage bytes named
    /// `.docx` do not always throw. Instead the reader can silently fall
    /// through to a bare plain-text interpretation and hand back the raw
    /// bytes as "content" (e.g. control characters `NUL SOH STX ETX`) — that
    /// is invented text, exactly what the failure rule forbids. We guard
    /// against it by inspecting the reader's own `documentType` in
    /// `documentAttributes`: for any structured extension (everything except
    /// HTML, which legitimately degrades to plain text for real HTML
    /// fragments) a `.plain` result means the reader never actually
    /// recognized the format — that is treated as a load failure, not a
    /// successful parse.
    public static func load(_ url: URL) throws -> RichTextEngine {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        var attributes: NSDictionary?
        do {
            let attributed = try NSAttributedString(
                url: url, options: options, documentAttributes: &attributes)
            let ext = url.pathExtension.lowercased()
            let isHTML = ext == "html" || ext == "htm"
            let documentType = attributes?[NSAttributedString.DocumentAttributeKey.documentType]
                as? NSAttributedString.DocumentType
            if !isHTML, documentType == .plain {
                return RichTextEngine(
                    sourceURL: url, attributed: NSAttributedString(string: ""),
                    loadFailure: "Lore couldn't read this \(url.pathExtension.uppercased()) file.")
            }
            return RichTextEngine(sourceURL: url, attributed: attributed, loadFailure: nil)
        } catch {
            return RichTextEngine(
                sourceURL: url, attributed: NSAttributedString(string: ""),
                loadFailure: "Lore couldn't read this \(url.pathExtension.uppercased()) file.")
        }
    }

    public func save(to url: URL) throws {
        throw EngineError.readOnly(url)
    }

    public var isEditable: Bool { false }

    public func replaceContents(with other: RichTextEngine) {
        sourceURL = other.sourceURL
        attributed = other.attributed
        loadFailure = other.loadFailure
    }

    public var indexTitle: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    public var indexPayload: IndexPayload {
        IndexPayload(title: indexTitle,
                     plaintext: VaultIndexCoordinator.capped(attributed.string))
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        if let loadFailure {
            return AnyView(DocumentErrorCard(url: sourceURL, message: loadFailure,
                                             theme: ctx.theme))
        }
        return AnyView(RichTextViewer(attributed: attributed)
            .background(ctx.theme.tokens.background))
    }
}

/// Read-only `NSTextView`. Not editable: the document's own attributes are
/// shown as authored, because reformatting someone's Word file to match
/// Lore's theme would misrepresent it.
@MainActor
private struct RichTextViewer: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(attributed)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.textStorage?.string != attributed.string {
            textView.textStorage?.setAttributedString(attributed)
        }
    }
}
