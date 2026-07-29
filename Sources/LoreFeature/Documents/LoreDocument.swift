import SwiftUI
import AinkradAppKit

/// A heading in a document, for outline navigation (M2 consumes this; M0 only
/// has to carry it so engines do not need a schema change later).
public struct OutlineEntry: Sendable, Equatable {
    public let level: Int
    public let text: String
    public init(level: Int, text: String) { self.level = level; self.text = text }
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
    /// Outbound link targets. Always empty in M0; M1 populates it.
    public var links: [String]

    public init(title: String, plaintext: String, tags: [String] = [],
                properties: [FrontmatterPair] = [], outline: [OutlineEntry] = [],
                links: [String] = [], id: String? = nil) {
        self.id = id
        self.title = title; self.plaintext = plaintext; self.tags = tags
        self.properties = properties; self.outline = outline; self.links = links
    }
}

/// What an engine's editor view needs from the shell.
public struct EditorContext {
    public let theme: HostTheme
    /// Called by the editor after every user mutation. The session debounces
    /// and saves; the editor never writes files itself.
    public let onChange: @MainActor () -> Void

    public init(theme: HostTheme, onChange: @escaping @MainActor () -> Void) {
        self.theme = theme; self.onChange = onChange
    }
}
