import Foundation
import GRDB

/// A link after resolution: what the author wrote, and what it points at.
///
/// Both halves are stored. `targetPath` drives backlinks and navigation;
/// `rawTarget` is what rename rewriting must find and replace, so that a link
/// written `[[design]]` is rewritten `[[new-name]]` rather than being silently
/// normalized to a full path.
public struct ResolvedLink: Sendable, Equatable {
    public let rawTarget: String
    public let targetPath: URL?
    public let isEmbed: Bool
    public init(rawTarget: String, targetPath: URL?, isEmbed: Bool) {
        self.rawTarget = rawTarget; self.targetPath = targetPath; self.isEmbed = isEmbed
    }
}

/// One document's contribution to the index: where it lives, which engine
/// claims it, and the payload that engine produced.
public struct IndexEntry: Sendable {
    public let url: URL
    public let type: String
    public let payload: IndexPayload
    public let updated: Date
    public let resolvedLinks: [ResolvedLink]
    public init(url: URL, type: String, payload: IndexPayload, updated: Date,
                resolvedLinks: [ResolvedLink] = []) {
        self.url = url; self.type = type; self.payload = payload; self.updated = updated
        self.resolvedLinks = resolvedLinks
    }
}

public struct IndexRow: Equatable, Sendable {
    public let path: URL
    public let id: String
    public let title: String
    public let tags: [String]
    public let aliases: [String]
    public let updated: Date
    public let type: String
    public let properties: [FrontmatterPair]
}

/// `@unchecked Sendable`: the only stored property is a GRDB `DatabaseQueue`,
/// which serializes every access internally and is safe to use from any thread.
/// This is what lets `LoreStore` run a whole-vault rebuild off the main actor.
public final class LoreIndex: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    /// Bump whenever the schema changes. On mismatch the file is deleted and
    /// rebuilt from disk — safe precisely because the index is derived state,
    /// so there is no migration SQL to get wrong.
    static let schemaVersion: Int32 = 3

    public init(path: URL) throws {
        // Probe the existing file's version in its own scope and CLOSE it
        // before deleting: unlinking a database file while a connection is
        // still open on it is an SQLite API violation ("vnode unlinked while
        // in use"), which libsqlite3 logs loudly and which leaves the reopened
        // handle pointing at a file nobody can reach.
        //
        // ANY failure to open, probe or close the existing file counts as
        // stale. The index is entirely derived state, so a corrupt or
        // truncated file must cost exactly one rescan — never the vault. Left
        // as a thrown error it propagates out of `activate`, and the user gets
        // a plugin that permanently refuses to open their notes because a
        // cache file went bad.
        if FileManager.default.fileExists(atPath: path.path) {
            var stale = true
            do {
                let probe = try DatabaseQueue(path: path.path)
                let version = try probe.read { db in
                    try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                }
                try probe.close()
                stale = version != Self.schemaVersion
            } catch {
                stale = true
            }
            if stale { Self.recreate(at: path) }
        }
        dbQueue = try DatabaseQueue(path: path.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS documents(
                    path TEXT PRIMARY KEY, id TEXT, title TEXT, tags TEXT,
                    aliases TEXT, updated DOUBLE, plaintext TEXT, type TEXT, properties TEXT);
            """)
            // Standalone FTS5 index keyed by the same rowid as `documents` (NOT
            // external-content: external-content tables corrupt on the manual
            // INSERT/DELETE we do in upsert/remove).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts
                USING fts5(title, plaintext);
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS links(
                    source_path TEXT NOT NULL,
                    raw_target  TEXT NOT NULL,
                    target_path TEXT,
                    is_embed    INTEGER NOT NULL DEFAULT 0);
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS links_by_target ON links(target_path);
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS links_by_source ON links(source_path);
            """)
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    /// Deletes the index file and its sidecars. Non-throwing on purpose: a
    /// missing file is the desired end state, so nothing here is an error the
    /// caller could act on.
    private static func recreate(at path: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                atPath: path.path + suffix)
        }
    }

    // MARK: - Property encoding

    // ASCII unit/record separators rather than JSON: property values are raw
    // YAML source text that may contain quotes, braces, and newlines, and
    // separators that cannot appear in a single-line YAML scalar are simpler
    // and cheaper than escaping. M5 replaces this with typed columns when
    // views need to query properties.

    private static func encode(_ properties: [FrontmatterPair]) -> String {
        properties.map { "\($0.key)\u{1F}\($0.rawValue)" }.joined(separator: "\u{1E}")
    }

    /// Known lossy edge: a property whose key or value literally contains
    /// U+001F or U+001E is dropped rather than mis-split. Unreachable today —
    /// `Frontmatter.parse` yields single-line, whitespace-trimmed scalars, and
    /// neither separator can appear in one — and M5's typed columns remove the
    /// encoding entirely.
    private static func decode(_ raw: String) -> [FrontmatterPair] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\u{1E}").compactMap { field in
            let parts = field.components(separatedBy: "\u{1F}")
            guard parts.count == 2 else { return nil }
            return FrontmatterPair(key: parts[0], rawValue: parts[1])
        }
    }

    // MARK: - Writes

    public func upsert(_ entry: IndexEntry) throws {
        try dbQueue.write { db in
            try Self.write(entry, into: db)
        }
    }

    private static func write(_ entry: IndexEntry, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO documents(path,id,title,tags,aliases,updated,plaintext,type,properties)
            VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                id=excluded.id, title=excluded.title, tags=excluded.tags,
                aliases=excluded.aliases,
                updated=excluded.updated, plaintext=excluded.plaintext,
                type=excluded.type, properties=excluded.properties;
        """, arguments: [entry.url.path, entry.payload.id ?? entry.url.path, entry.payload.title,
                         entry.payload.tags.joined(separator: ","),
                         entry.payload.aliases.joined(separator: ","),
                         entry.updated.timeIntervalSince1970,
                         entry.payload.plaintext, entry.type,
                         encode(entry.payload.properties)])
        let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path=?",
                                       arguments: [entry.url.path])
        try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
        try db.execute(sql: "INSERT INTO documents_fts(rowid,title,plaintext) VALUES(?,?,?)",
                       arguments: [rowid, entry.payload.title, entry.payload.plaintext])
        try db.execute(sql: "DELETE FROM links WHERE source_path = ?",
                       arguments: [entry.url.path])
        for link in entry.resolvedLinks {
            try db.execute(sql: """
                INSERT INTO links(source_path, raw_target, target_path, is_embed)
                VALUES(?,?,?,?);
            """, arguments: [entry.url.path, link.rawTarget,
                             link.targetPath?.path, link.isEmbed ? 1 : 0])
        }
    }

    /// Replaces the whole index with `entries`, in a SINGLE write transaction.
    ///
    /// `rebuild` used to call `upsert` per note and then `remove` per stale
    /// row — one SQLite transaction each. A vault with a few thousand notes
    /// meant a few thousand transactions, every one of them an fsync, all on
    /// the main actor. Batching them into one transaction is most of why a
    /// rescan is now fast enough to be unnoticeable.
    public func replaceAll(with entries: [IndexEntry]) throws {
        try dbQueue.write { db in
            let keep = Set(entries.map(\.url.path))
            for entry in entries {
                try Self.write(entry, into: db)
            }
            // Prune rows whose backing file is gone.
            let stale = try String.fetchAll(db, sql: "SELECT path FROM documents")
                .filter { !keep.contains($0) }
            for path in stale {
                let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path=?",
                                               arguments: [path])
                try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM documents WHERE path=?", arguments: [path])
                try db.execute(sql: "DELETE FROM links WHERE source_path = ?", arguments: [path])
            }
        }
    }

    public func remove(path: URL) throws {
        try dbQueue.write { db in
            let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path=?",
                                           arguments: [path.path])
            try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM documents WHERE path=?", arguments: [path.path])
            try db.execute(sql: "DELETE FROM links WHERE source_path = ?", arguments: [path.path])
        }
    }

    // MARK: - Reads

    public func all() throws -> [IndexRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM documents ORDER BY updated DESC").map(Self.row)
        }
    }

    public func search(_ query: String) throws -> [IndexRow] {
        guard let expression = Self.ftsExpression(for: query) else { return try all() }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.* FROM documents n
                JOIN documents_fts f ON f.rowid = n.rowid
                WHERE documents_fts MATCH ? ORDER BY rank;
            """, arguments: [expression]).map(Self.row)
        }
    }

    /// `search` throwing is never actionable at a call site; this is the shape
    /// every caller already used via `try?`.
    public func searchOrEmpty(_ query: String) -> [IndexRow] {
        (try? search(query)) ?? []
    }

    /// Turns raw user input into a safe FTS5 MATCH expression, or `nil` when
    /// there is nothing to search for.
    ///
    /// The binding was already a SQL *parameter*, so this was never SQL
    /// injection — but a parameter passed to `MATCH` is still parsed by SQLite
    /// as an **FTS5 query expression**, and the raw string was handed over
    /// verbatim. So ordinary text broke it:
    ///
    /// * `size: 3` → `:` is the column filter operator → syntax error
    /// * `he said "hi` → unbalanced quote → syntax error
    /// * `AND`, `OR`, `NOT`, `NEAR` → bare operators → syntax error
    /// * `C++` / `a-b` → operator characters → syntax error
    ///
    /// A thrown error here is worse than it sounds: every call site uses
    /// `try?`, so a syntax error becomes an empty result set and the note
    /// browser silently reports "no matches" for a note that exists. Typing a
    /// colon made search look broken.
    ///
    /// Each whitespace-separated term is emitted as a quoted FTS5 string
    /// literal (embedded `"` doubled, per the FTS5 grammar) with a trailing
    /// `*` for prefix matching, joined by implicit AND. Inside a quoted
    /// literal every character is data, so no input can be an operator.
    static func ftsExpression(for query: String) -> String? {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { term -> String in
                let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    private static func row(_ r: Row) -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: r["path"]),
                 id: r["id"], title: r["title"],
                 tags: (r["tags"] as String).split(separator: ",").map(String.init),
                 aliases: (r["aliases"] as String).split(separator: ",").map(String.init),
                 updated: Date(timeIntervalSince1970: r["updated"]),
                 type: r["type"],
                 properties: decode(r["properties"]))
    }

    // MARK: - Links

    /// Documents containing a link that resolves to `target`.
    public func backlinks(to target: URL) throws -> [IndexRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT d.* FROM documents d
                JOIN links l ON l.source_path = d.path
                WHERE l.target_path = ?
                ORDER BY d.updated DESC;
            """, arguments: [target.path]).map(Self.row)
        }
    }

    /// Every (file, rawTarget) pair pointing at `target`.
    ///
    /// Distinct from `backlinks(to:)`, which returns one row per SOURCE
    /// DOCUMENT: a rename must rewrite every individual link, so a document
    /// linking twice with two different spellings (`[[Design]]` and
    /// `[[Projects/Design.md]]`) has to yield two rows here, not one.
    public func inboundLinks(to target: URL) throws -> [(sourceFile: URL, rawTarget: String)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT source_path, raw_target FROM links
                WHERE target_path = ?;
            """, arguments: [target.path]).map { r -> (sourceFile: URL, rawTarget: String) in
                let source: String = r["source_path"]
                let raw: String = r["raw_target"]
                return (sourceFile: URL(fileURLWithPath: source), rawTarget: raw)
            }
        }
    }

    /// This document's outbound links that resolve to nothing. A normal state:
    /// it is how a link to a not-yet-written note behaves.
    public func unresolvedLinks(from source: URL) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT raw_target FROM links
                WHERE source_path = ? AND target_path IS NULL;
            """, arguments: [source.path])
        }
    }

    public func outgoingLinks(from source: URL) throws -> [ResolvedLink] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT raw_target, target_path, is_embed FROM links
                WHERE source_path = ?;
            """, arguments: [source.path]).map { r in
                ResolvedLink(rawTarget: r["raw_target"],
                             targetPath: (r["target_path"] as String?).map {
                                 URL(fileURLWithPath: $0)
                             },
                             isEmbed: (r["is_embed"] as Int) == 1)
            }
        }
    }
}
