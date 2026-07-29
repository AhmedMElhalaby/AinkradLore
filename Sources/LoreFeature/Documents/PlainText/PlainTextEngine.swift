import SwiftUI
import AinkradAppKit

/// Plain text and source files: no frontmatter, no structure, the file's bytes
/// are the document.
///
/// Deliberately the dumbest possible engine. Its job in M0 is to prove the
/// shell contains no markdown assumptions — if anything here needs a special
/// case in `VaultIndexCoordinator` or `DocumentSession`, the abstraction leaks.
public final class PlainTextEngine: DocumentEngine {
    public static let identifier = "plaintext"

    public var text: String
    private let sourceURL: URL

    private init(text: String, sourceURL: URL) {
        self.text = text; self.sourceURL = sourceURL
    }

    public static let extensions: Set<String> = [
        "txt", "text", "log", "csv", "json", "yaml", "yml", "toml",
        "swift", "sh", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp",
    ]

    public static func canOpen(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func load(_ url: URL) throws -> PlainTextEngine {
        // Not every file with a text extension is valid UTF-8. Falling back to
        // a lossy decode keeps a mis-encoded log openable and searchable rather
        // than making it an error state the user cannot act on.
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        return PlainTextEngine(text: text, sourceURL: url)
    }

    public func save(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public var indexPayload: IndexPayload {
        IndexPayload(title: sourceURL.deletingPathExtension().lastPathComponent,
                     plaintext: text)
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        AnyView(PlainTextDocumentEditor(engine: self, ctx: ctx))
    }
}

@MainActor
private struct PlainTextDocumentEditor: View {
    let engine: PlainTextEngine
    let ctx: EditorContext
    @State private var text: String = ""

    var body: some View {
        MarkdownEditor(text: $text, tokens: ctx.theme.tokens)
            .onChange(of: text) { engine.text = text; ctx.onChange() }
            .onAppear { text = engine.text }
            .background(ctx.theme.tokens.background)
    }
}
