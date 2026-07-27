import Foundation
import GRDB

public struct IndexRow: Equatable, Sendable {
    public let path: URL; public let id: String; public let title: String
    public let tags: [String]; public let updated: Date
}

/// `@unchecked Sendable`: the only stored property is a GRDB `DatabaseQueue`,
/// which serializes every access internally and is safe to use from any thread.
/// This is what lets `LoreStore` run a whole-vault rebuild off the main actor.
public final class LoreIndex: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: URL) throws {
        dbQueue = try DatabaseQueue(path: path.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS notes(
                    path TEXT PRIMARY KEY, id TEXT, title TEXT,
                    tags TEXT, updated DOUBLE, body TEXT);
            """)
            // Standalone FTS5 index keyed by the same rowid as `notes` (NOT external-content:
            // external-content tables corrupt on the manual INSERT/DELETE we do in upsert/remove).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts
                USING fts5(title, body);
            """)
        }
    }

    public func upsert(_ note: Note) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO notes(path,id,title,tags,updated,body)
                VALUES(?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET
                    id=excluded.id, title=excluded.title, tags=excluded.tags,
                    updated=excluded.updated, body=excluded.body;
            """, arguments: [note.path.path, note.id, note.title,
                             note.tags.joined(separator: ","),
                             note.updated.timeIntervalSince1970, note.body])
            let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM notes WHERE path=?",
                                           arguments: [note.path.path])
            try db.execute(sql: "DELETE FROM notes_fts WHERE rowid=?", arguments: [rowid])
            try db.execute(sql: "INSERT INTO notes_fts(rowid,title,body) VALUES(?,?,?)",
                           arguments: [rowid, note.title, note.body])
        }
    }

    /// Replaces the whole index with `notes`, in a SINGLE write transaction.
    ///
    /// `rebuild` used to call `upsert` per note and then `remove` per stale
    /// row — one SQLite transaction each. A vault with a few thousand notes
    /// meant a few thousand transactions, every one of them an fsync, all on
    /// the main actor. Batching them into one transaction is most of why a
    /// rescan is now fast enough to be unnoticeable.
    public func replaceAll(with notes: [Note]) throws {
        try dbQueue.write { db in
            let keep = Set(notes.map(\.path.path))
            for note in notes {
                try db.execute(sql: """
                    INSERT INTO notes(path,id,title,tags,updated,body)
                    VALUES(?,?,?,?,?,?)
                    ON CONFLICT(path) DO UPDATE SET
                        id=excluded.id, title=excluded.title, tags=excluded.tags,
                        updated=excluded.updated, body=excluded.body;
                """, arguments: [note.path.path, note.id, note.title,
                                 note.tags.joined(separator: ","),
                                 note.updated.timeIntervalSince1970, note.body])
                let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM notes WHERE path=?",
                                               arguments: [note.path.path])
                try db.execute(sql: "DELETE FROM notes_fts WHERE rowid=?", arguments: [rowid])
                try db.execute(sql: "INSERT INTO notes_fts(rowid,title,body) VALUES(?,?,?)",
                               arguments: [rowid, note.title, note.body])
            }
            // Prune rows whose backing file is gone.
            let stale = try String.fetchAll(db, sql: "SELECT path FROM notes")
                .filter { !keep.contains($0) }
            for path in stale {
                let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM notes WHERE path=?",
                                               arguments: [path])
                try db.execute(sql: "DELETE FROM notes_fts WHERE rowid=?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM notes WHERE path=?", arguments: [path])
            }
        }
    }

    public func remove(path: URL) throws {
        try dbQueue.write { db in
            let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM notes WHERE path=?",
                                           arguments: [path.path])
            try db.execute(sql: "DELETE FROM notes_fts WHERE rowid=?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM notes WHERE path=?", arguments: [path.path])
        }
    }

    public func all() throws -> [IndexRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notes ORDER BY updated DESC").map(Self.row)
        }
    }

    public func search(_ query: String) throws -> [IndexRow] {
        guard let expression = Self.ftsExpression(for: query) else { return try all() }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.* FROM notes n
                JOIN notes_fts f ON f.rowid = n.rowid
                WHERE notes_fts MATCH ? ORDER BY rank;
            """, arguments: [expression]).map(Self.row)
        }
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
        IndexRow(path: URL(fileURLWithPath: r["path"]), id: r["id"], title: r["title"],
                 tags: (r["tags"] as String).split(separator: ",").map(String.init),
                 updated: Date(timeIntervalSince1970: r["updated"]))
    }
}
