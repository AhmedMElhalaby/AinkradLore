import SwiftUI
import AinkradAppKit

/// A heading in a document, for outline navigation (M2 consumes this; M0 only
/// has to carry it so engines do not need a schema change later).
public struct OutlineEntry: Sendable, Equatable {
    public let level: Int
    public let text: String
    /// UTF-16 offset of the heading, relative to whatever string the
    /// PRODUCING engine parsed to build this outline — NOT necessarily the
    /// on-disk file's full text. There is no runtime check tying this to an
    /// editor's coordinate space; the contract is exactly "whatever string
    /// the engine that built this outline handed its scroll-to-offset entry
    /// point". For `MarkdownEngine` that string is `note.body` — frontmatter
    /// EXCLUDED — because `MarkdownDocumentEditor` binds the editor's text to
    /// `engine.note.body` (the title lives in a separate field), so an offset
    /// counted from a serialized "frontmatter + body" string would be off by
    /// the frontmatter's length the moment it reached the editor. An engine
    /// producing offsets against a different string than the one its own
    /// editor scrolls will misplace every click silently — offset math is
    /// dropped, never guessed, everywhere else in this codebase; this field
    /// is the one place a wrong convention would not even fail loudly.
    /// Defaulted so existing construction sites (tests, other engines) keep
    /// compiling.
    public let utf16Offset: Int
    public init(level: Int, text: String, utf16Offset: Int = 0) {
        self.level = level; self.text = text; self.utf16Offset = utf16Offset
    }
}

/// Everything the shell needs to index a document, supplied BY the engine.
///
/// The shell never re-reads a document's file to index it. That indirection is
/// what lets a PDF or a `.lore` package contribute searchable text it does not
/// literally contain as bytes.
public struct IndexPayload: Sendable {
    /// Stable document identity, when the format has one of its own (markdown's
    /// `id:` frontmatter key). `nil` means "no intrinsic identity" and the
    /// index falls back to the file path — which is what a plain text file has.
    /// Callers that resolve a document by name (the MCP layer) match on this.
    public var id: String?
    public var title: String
    public var plaintext: String
    public var tags: [String]
    public var properties: [FrontmatterPair]
    public var outline: [OutlineEntry]
    /// Outbound links, in document order. Populated by M1.
    public var links: [DocumentLink]
    /// Alternate names this document answers to, from frontmatter `aliases`.
    public var aliases: [String]

    public init(title: String, plaintext: String, tags: [String] = [],
                properties: [FrontmatterPair] = [], outline: [OutlineEntry] = [],
                links: [DocumentLink] = [], aliases: [String] = [], id: String? = nil) {
        self.id = id
        self.title = title; self.plaintext = plaintext; self.tags = tags
        self.properties = properties; self.outline = outline; self.links = links
        self.aliases = aliases
    }
}

/// What an engine's editor view needs from the shell.
public struct EditorContext {
    public let theme: HostTheme
    /// Called by the editor after every user mutation. The session debounces
    /// and saves; the editor never writes files itself.
    public let onChange: @MainActor () -> Void
    /// Candidate documents for a `[[` prefix. Defaulted to "no candidates" so
    /// widening this struct cannot break an engine or a call site that has no
    /// link layer to offer — an engine that ignores it behaves exactly as
    /// before.
    public let completions: @MainActor (String) -> [IndexRow]
    /// Open a wikilink target the user activated in the editor.
    public let openLink: @MainActor (String) -> Void
    /// Resolves an `![[target]]` embed's raw target to a file, for inline
    /// image / chip rendering (`EmbedRendering`). Defaulted to "nothing
    /// resolves", the same "no link layer" default `completions` and
    /// `openLink` already have, so an engine that ignores it behaves exactly
    /// as before.
    public let resolveEmbedTarget: @MainActor (String) -> URL?
    /// The text to write for a picked completion. Supplied by the shell because
    /// only the shell can check that the target resolves back to that document
    /// — see `LoreStore.linkTarget(for:)`. The default is the store-blind
    /// approximation, which is right for an engine with no link layer.
    public let linkTarget: @MainActor (IndexRow) -> String
    /// Lets the editor hand the shell a "scroll to this offset" function,
    /// without the shell reaching into the editor's internals to get one.
    /// `OutlineSection` lives in `DocumentPane`, a sibling of whatever view
    /// `makeEditor` returns — not a descendant of it — so this closure is the
    /// only channel between the two. Defaulted to a no-op so an engine with no
    /// outline (or no editor that supports scrolling at all) needs no changes.
    public let registerScrollHandler: @MainActor (@escaping @MainActor (Int) -> Void) -> Void
    /// The session refuses to write this document, so `onChange` cannot lead
    /// anywhere: `DocumentSession.markChanged()` returns immediately for a
    /// read-only session and `saveNow()` throws. An editor uses this to
    /// withhold affordances that would otherwise PROMISE persistence — today
    /// the task-checkbox toggle. Defaulted to writable so an engine or a test
    /// that does not care behaves exactly as before.
    public let isReadOnly: Bool
    /// Writes pasted image bytes as an attachment BESIDE the open document
    /// and returns the `![[name]]` embed text to insert at the caret, or
    /// `nil` if the write failed (no vault, no permission, …) — in which
    /// case the editor drops the paste rather than inserting a link to
    /// nothing. Defaulted to "cannot write", the same shape every other
    /// store-backed capability here defaults to, so an engine with no
    /// attachment story (or a read-only session) needs no changes.
    public let writePastedImage: @MainActor (Data, String) -> String?
    /// Copies a dropped file into the vault BESIDE the open document and
    /// returns the `![[name]]` embed text to insert. Same "nil means declined
    /// or failed" contract as `writePastedImage`.
    public let writeDroppedFile: @MainActor (URL) -> String?

    public init(theme: HostTheme, onChange: @escaping @MainActor () -> Void,
                completions: @escaping @MainActor (String) -> [IndexRow] = { _ in [] },
                openLink: @escaping @MainActor (String) -> Void = { _ in },
                resolveEmbedTarget: @escaping @MainActor (String) -> URL? = { _ in nil },
                linkTarget: @escaping @MainActor (IndexRow) -> String
                    = { LinkCompletionContext.insertableTarget(for: $0) },
                registerScrollHandler: @escaping @MainActor (@escaping @MainActor (Int) -> Void) -> Void
                    = { _ in },
                isReadOnly: Bool = false,
                writePastedImage: @escaping @MainActor (Data, String) -> String? = { _, _ in nil },
                writeDroppedFile: @escaping @MainActor (URL) -> String? = { _ in nil }) {
        self.theme = theme; self.onChange = onChange
        self.completions = completions; self.openLink = openLink
        self.resolveEmbedTarget = resolveEmbedTarget
        self.linkTarget = linkTarget
        self.registerScrollHandler = registerScrollHandler
        self.isReadOnly = isReadOnly
        self.writePastedImage = writePastedImage
        self.writeDroppedFile = writeDroppedFile
    }
}
