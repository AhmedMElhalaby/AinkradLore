import Foundation

public struct FrontmatterPair: Equatable, Sendable {
    public let key: String
    public let rawValue: String
    public init(key: String, rawValue: String) { self.key = key; self.rawValue = rawValue }
}

public struct Note: Identifiable, Equatable, Sendable {
    public let path: URL
    public var id: String
    public var title: String
    public var tags: [String]
    public var created: Date
    public var updated: Date
    public var body: String
    /// The unmodelled `key: value` pairs, flattened to one line each.
    ///
    /// DERIVED, read-only-in-spirit: it feeds `IndexPayload.properties` so
    /// property views can query them. It is NOT used to write the file — see
    /// `rawFrontmatter` — so the two cannot disagree about what lands on disk.
    public var extra: [FrontmatterPair]

    /// The document's original frontmatter block, verbatim, without its `---`
    /// fences. `nil` when the file had no frontmatter at all.
    ///
    /// This is the source of truth for serialization: `Frontmatter.serialize`
    /// patches modelled keys into this text instead of re-emitting a block from
    /// the model, so everything Lore does not model survives a save intact.
    public var rawFrontmatter: String?

    /// The line ending the file was written with, `"\n"` or `"\r\n"`.
    ///
    /// Carried so a CRLF document — Windows-authored vaults, sync clients, git
    /// checkouts with `core.autocrlf` — is re-emitted with the endings it
    /// arrived with. Normalising them would rewrite every line of the file,
    /// which is its own kind of corruption.
    public var lineEnding: String

    public init(path: URL, id: String, title: String, tags: [String],
                created: Date, updated: Date, body: String, extra: [FrontmatterPair] = [],
                rawFrontmatter: String? = nil, lineEnding: String = "\n") {
        self.path = path; self.id = id; self.title = title; self.tags = tags
        self.created = created; self.updated = updated; self.body = body
        self.extra = extra; self.rawFrontmatter = rawFrontmatter
        self.lineEnding = lineEnding
    }
}
