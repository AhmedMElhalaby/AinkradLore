import Foundation
import GRDB

public struct IndexRow: Equatable, Sendable {
    public let path: URL; public let id: String; public let title: String
    public let tags: [String]; public let updated: Date
}

public final class LoreIndex {
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
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return try all() }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.* FROM notes n
                JOIN notes_fts f ON f.rowid = n.rowid
                WHERE notes_fts MATCH ? ORDER BY rank;
            """, arguments: ["\(trimmed)*"]).map(Self.row)
        }
    }

    private static func row(_ r: Row) -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: r["path"]), id: r["id"], title: r["title"],
                 tags: (r["tags"] as String).split(separator: ",").map(String.init),
                 updated: Date(timeIntervalSince1970: r["updated"]))
    }
}
