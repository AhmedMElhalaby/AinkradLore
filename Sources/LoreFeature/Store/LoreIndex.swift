import Foundation
import GRDB

/// One document's contribution to the index: where it lives, which engine
/// claims it, and the payload that engine produced.
public struct IndexEntry: Sendable {
    public let url: URL
    public let type: String
    public let payload: IndexPayload
    public let updated: Date
    public init(url: URL, type: String, payload: IndexPayload, updated: Date) {
        self.url = url; self.type = type; self.payload = payload; self.updated = updated
    }
}

public struct IndexRow: Equatable, Sendable {
    public let path: URL
    public let id: String
    public let title: String
    public let tags: [String]
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
    static let schemaVersion: Int32 = 2

    public init(path: URL) throws {
        // Probe the existing file's version in its own scope and CLOSE it
        // before deleting: unlinking a database file while a connection is
        // still open on it is an SQLite API violation ("vnode unlinked while
        // in use"), which libsqlite3 logs loudly and which leaves the reopened
        // handle pointing at a file nobody can reach.
        if FileManager.default.fileExists(atPath: path.path) {
            let stale: Bool
            do {
                let probe = try DatabaseQueue(path: path.path)
                stale = try probe.read { db in
                    try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                } != Self.schemaVersion
                try probe.close()
            }
            if stale { try Self.recreate(at: path) }
        }
        dbQueue = try DatabaseQueue(path: path.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS documents(
                    path TEXT PRIMARY KEY, id TEXT, title TEXT, tags TEXT,
                    updated DOUBLE, plaintext TEXT, type TEXT, properties TEXT);
            """)
            // Standalone FTS5 index keyed by the same rowid as `documents` (NOT
            // external-content: external-content tables corrupt on the manual
            // INSERT/DELETE we do in upsert/remove).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts
                USING fts5(title, plaintext);
            """)
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    private static func recreate(at path: URL) throws {
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
            INSERT INTO documents(path,id,title,tags,updated,plaintext,type,properties)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                id=excluded.id, title=excluded.title, tags=excluded.tags,
                updated=excluded.updated, plaintext=excluded.plaintext,
                type=excluded.type, properties=excluded.properties;
        """, arguments: [entry.url.path, entry.payload.id ?? entry.url.path, entry.payload.title,
                         entry.payload.tags.joined(separator: ","),
                         entry.updated.timeIntervalSince1970,
                         entry.payload.plaintext, entry.type,
                         encode(entry.payload.properties)])
        let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path=?",
                                       arguments: [entry.url.path])
        try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
        try db.execute(sql: "INSERT INTO documents_fts(rowid,title,plaintext) VALUES(?,?,?)",
                       arguments: [rowid, entry.payload.title, entry.payload.plaintext])
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
            }
        }
    }

    public func remove(path: URL) throws {
        try dbQueue.write { db in
            let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path=?",
                                           arguments: [path.path])
            try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM documents WHERE path=?", arguments: [path.path])
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
                 updated: Date(timeIntervalSince1970: r["updated"]),
                 type: r["type"],
                 properties: decode(r["properties"]))
    }
}
