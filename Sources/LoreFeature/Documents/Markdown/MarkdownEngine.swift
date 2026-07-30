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

    /// Built from `note.body` alone, not the serialized note (frontmatter and
    /// all). `MarkdownDocumentEditor` binds `MarkdownEditor`'s `text` to
    /// `engine.note.body` — the title lives in a separate field — so every
    /// offset the editor's styling model computes (`MarkdownStyleCache.derive`
    /// parses that same `body_` string) is body-relative. Building the outline
    /// from full frontmatter+body text would shift every `utf16Offset` by the
    /// frontmatter's length, and the click-to-scroll entry point would land in
    /// the wrong place. `note.body` keeps this consistent with the editor by
    /// construction, not by convention.
    public var indexPayload: IndexPayload {
        let model = MarkdownDocumentModel(fullText: note.body)
        return IndexPayload(title: note.title,
                     plaintext: note.body,
                     tags: note.tags,
                     properties: note.extra,
                     outline: model.outline,
                     links: LinkParser.links(in: note.body),
                     aliases: note.aliases,
                     id: note.id)
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
    /// Set by `ctx.registerScrollHandler`'s callback, which `OutlineSection`
    /// invokes through the closure the shell captured. Body-relative UTF-16 —
    /// see `MarkdownEngine.indexPayload`'s doc comment for why that is what
    /// `outline` offsets already are.
    @State private var scrollTarget: Int?

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
                           linkTarget: ctx.linkTarget, scrollTarget: $scrollTarget)
                .onChange(of: body_) { engine.note.body = body_; ctx.onChange() }
        }
        .background(ctx.theme.tokens.background)
        .onAppear {
            title = engine.note.title; body_ = engine.note.body
            ctx.registerScrollHandler { offset in scrollTarget = offset }
        }
    }
}
