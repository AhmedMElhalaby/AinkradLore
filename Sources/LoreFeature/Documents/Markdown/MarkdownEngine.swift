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
    /// construction, not by convention. See `OutlineEntry.utf16Offset`'s doc
    /// comment for the general contract this is an instance of.
    ///
    /// `init(body:)` because `note.body` has ALREADY had any real frontmatter
    /// separated out by `Frontmatter.parse`. `init(fullText:)` would run
    /// `Frontmatter.bodyOffset` a second time over text that is no longer
    /// frontmatter-prefixed, and a body that happens to open with something
    /// fence-shaped (an `---` rule, later followed by another bare `---`) would
    /// have that whole span misread as frontmatter and dropped from the parse —
    /// see `MarkdownDocumentModel.init(body:)`.
    ///
    /// A dedicated accessor, not folded into `indexPayload`: `DocumentPane`
    /// wants the outline on its own, on a cadence tighter than a full
    /// `indexPayload` (title/tags/properties/links) is worth recomputing for.
    /// Reaching through `indexPayload` for just the outline would also run
    /// `LinkParser.links(in:)` — a second, unrelated scan — for no reason.
    public var outline: [OutlineEntry] {
        MarkdownDocumentModel(body: note.body).outline
    }

    /// The title is a stored field of the parsed frontmatter — no markdown
    /// parse involved. Overriding the protocol's `indexPayload.title` default
    /// is what keeps `DocumentSession`'s four title refreshes free; see
    /// `DocumentEngine.indexTitle`.
    public var indexTitle: String { note.title }

    /// ONE parse, feeding both halves.
    ///
    /// This used to read `outline` (a `MarkdownDocumentModel`) and then call
    /// `LinkParser.links(in:)`, which builds a SECOND, identical model of the
    /// same body to answer "is this offset inside code?". Nothing was shared,
    /// so every `indexPayload` cost two full AST parses — on the main actor in
    /// the save path, and once per note across a whole-vault rebuild.
    ///
    /// The seam already existed: the model can hand `LinkParser` the
    /// suppression index it just built (`MarkdownDocumentModel.links`), which
    /// is exactly what `wikilinkSpans` does for the styling path. CRLF bodies
    /// still cost two, deliberately — the model withholds its index there
    /// because `LinkParser` normalises before scanning and pre-normalisation
    /// UTF-16 offsets would misplace suppression. Correctness over the saved
    /// parse; see `injectableSuppressionIndex`.
    public var indexPayload: IndexPayload {
        let model = MarkdownDocumentModel(body: note.body)
        return IndexPayload(title: note.title,
                            plaintext: note.body,
                            tags: note.tags,
                            properties: note.extra,
                            outline: model.outline,
                            links: model.links,
                            aliases: note.aliases,
                            id: note.id)
    }

    public func replaceContents(with other: MarkdownEngine) {
        note = other.note
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
    /// see `MarkdownEngine.outline`'s doc comment for why that is what
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
                           resolveEmbedTarget: ctx.resolveEmbedTarget,
                           linkTarget: ctx.linkTarget, scrollTarget: $scrollTarget,
                           // Task checkboxes are markdown, and only a session
                           // that can actually be written may offer to flip
                           // one — see `EditorContext.isReadOnly`.
                           allowsTaskToggle: !ctx.isReadOnly)
                .onChange(of: body_) { engine.note.body = body_; ctx.onChange() }
        }
        .background(ctx.theme.tokens.background)
        .onAppear {
            title = engine.note.title; body_ = engine.note.body
            ctx.registerScrollHandler { offset in scrollTarget = offset }
        }
    }
}
