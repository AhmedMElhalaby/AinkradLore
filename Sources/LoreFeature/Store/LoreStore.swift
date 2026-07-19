import Foundation
import Observation
import AinkradAppKit

@MainActor
@Observable
public final class LoreStore {
    public private(set) var rows: [IndexRow] = []
    public private(set) var vaultRoot: URL?

    private let documents: PluginDocumentStore
    private let indexPath: URL
    private var index: LoreIndex?
    private var watcher: FolderWatcher?
    private var openMTimes: [URL: Date] = [:]

    public init(documents: PluginDocumentStore, indexPath: URL) {
        self.documents = documents
        self.indexPath = indexPath
        if let root = VaultBookmark.resolve(from: documents) {
            try? activate(root: root)
        }
    }

    public func setVaultRoot(_ url: URL) throws {
        try VaultBookmark.save(url, to: documents)
        try activate(root: url)
    }

    /// Test seam: activate without a security-scoped bookmark.
    func setVaultRootForTesting(_ url: URL) throws { try activate(root: url) }

    private func activate(root: URL) throws {
        vaultRoot = root
        index = try LoreIndex(path: indexPath)
        try rebuild()
        watcher = FolderWatcher(url: root) { [weak self] in try? self?.rebuild() }
    }

    public func rebuild() throws {
        guard let root = vaultRoot, let index else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.pathExtension == "md" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try index.upsert(Frontmatter.parse(text, path: url))
        }
        rows = try index.all()
    }

    public func load(_ row: IndexRow) throws -> Note {
        let text = try String(contentsOf: row.path, encoding: .utf8)
        let note = Frontmatter.parse(text, path: row.path)
        openMTimes[row.path] = try mtime(of: row.path)
        return note
    }

    @discardableResult
    public func create(title: String) throws -> Note {
        guard let root = vaultRoot, let index else { throw LoreError.noVault }
        let slug = title.isEmpty ? "untitled" : title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let url = uniqueURL(in: root, slug: slug)
        let now = Date()
        let note = Note(path: url, id: UUID().uuidString, title: title, tags: [],
                        created: now, updated: now, body: "")
        try Frontmatter.serialize(note).write(to: url, atomically: true, encoding: .utf8)
        try index.upsert(note)
        rows = try index.all()
        openMTimes[url] = try mtime(of: url)
        return note
    }

    public func save(_ note: Note) throws {
        guard let index else { throw LoreError.noVault }
        var updated = note; updated.updated = Date()
        try Frontmatter.serialize(updated).write(to: note.path, atomically: true, encoding: .utf8)
        try index.upsert(updated)
        rows = try index.all()
        openMTimes[note.path] = try mtime(of: note.path)
    }

    public func delete(_ row: IndexRow) throws {
        guard let index else { throw LoreError.noVault }
        try? FileManager.default.removeItem(at: row.path)
        try index.remove(path: row.path)
        openMTimes[row.path] = nil
        rows = try index.all()
    }

    public func search(_ query: String) -> [IndexRow] {
        (try? index?.search(query)) ?? []
    }

    /// True if the file changed on disk since we last loaded/saved it.
    public func externalChangeDetected(for note: Note) -> Bool {
        guard let known = openMTimes[note.path], let disk = try? mtime(of: note.path) else { return false }
        return disk > known
    }

    private func mtime(of url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? .distantPast
    }

    private func uniqueURL(in root: URL, slug: String) -> URL {
        var candidate = root.appendingPathComponent("\(slug).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(slug)-\(n).md"); n += 1
        }
        return candidate
    }
}

public enum LoreError: Error { case noVault }
