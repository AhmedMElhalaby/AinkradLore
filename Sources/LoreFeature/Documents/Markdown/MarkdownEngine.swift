import SwiftUI
import AinkradAppKit

/// Markdown documents: plain `.md` with YAML frontmatter, read and written
/// verbatim and safe to open in Obsidian.
///
/// A thin adapter over the existing `Note` + `Frontmatter` pair. Loading and
/// saving must stay byte-identical to what `LoreStore` did before M0 — this is
/// an extraction, not a rewrite.
public final class MarkdownEngine: DocumentEngine {
    public static let identifier = "markdown"

    public var note: Note

    private init(note: Note) { self.note = note }

    public static func canOpen(_ url: URL) -> Bool {
        ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
    }

    public static func load(_ url: URL) throws -> MarkdownEngine {
        let text = try String(contentsOf: url, encoding: .utf8)
        return MarkdownEngine(note: Frontmatter.parse(text, path: url))
    }

    public func save(to url: URL) throws {
        try Frontmatter.serialize(note).write(to: url, atomically: true, encoding: .utf8)
    }

    public var indexPayload: IndexPayload {
        IndexPayload(title: note.title,
                     plaintext: note.body,
                     tags: note.tags,
                     properties: note.extra,
                     outline: Self.outline(of: note.body),
                     links: LinkParser.links(in: note.body),
                     aliases: note.aliases,
                     id: note.id)
    }

    /// ATX headings only (`# ` … `###### `). Setext headings are rare in
    /// generated vaults and M2 owns full markdown parsing; keeping this
    /// deliberately dumb avoids two competing parsers.
    static func outline(of body: String) -> [OutlineEntry] {
        body.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let hashes = line.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count),
                  line.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
            let text = line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : OutlineEntry(level: hashes.count, text: text)
        }
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        AnyView(MarkdownDocumentEditor(engine: self, ctx: ctx))
    }
}

/// The markdown engine's editor. Owns no persistence: it mutates the engine's
/// note and calls `ctx.onChange`, and `DocumentSession` decides when to write.
@MainActor
private struct MarkdownDocumentEditor: View {
    let engine: MarkdownEngine
    let ctx: EditorContext
    @State private var title: String = ""
    @State private var body_: String = ""

    var body: some View {
        VStack(spacing: 0) {
            AinkradTextField(text: $title, placeholder: "Title")
                .padding(AinkradSpacing.md)
                .onChange(of: title) { engine.note.title = title; ctx.onChange() }

            // Only markdown gets the link affordances: wikilinks are markdown
            // syntax, and offering completion inside a plain-text file would
            // insert brackets that mean nothing there.
            MarkdownEditor(text: $body_, tokens: ctx.theme.tokens,
                           completions: ctx.completions, onOpenLink: ctx.openLink,
                           linkTarget: ctx.linkTarget)
                .onChange(of: body_) { engine.note.body = body_; ctx.onChange() }
        }
        .background(ctx.theme.tokens.background)
        .onAppear { title = engine.note.title; body_ = engine.note.body }
    }
}
