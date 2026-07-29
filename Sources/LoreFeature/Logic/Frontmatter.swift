import Foundation

public enum Frontmatter {
    private static let iso: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .init(identifier: "UTC"); return f
    }()

    public static func parse(_ text: String, path: URL) -> Note {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return fallback(text, path: path)
        }
        let header = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
        var body = String(text[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        var kv: [String: String] = [:]
        let modelled: Set<String> = ["id", "title", "tags", "created", "updated"]
        var extra: [FrontmatterPair] = []
        for line in header.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            kv[key] = value
            if !modelled.contains(key) { extra.append(FrontmatterPair(key: key, rawValue: value)) }
        }
        let now = Date()
        return Note(
            path: path,
            id: kv["id"].flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
            title: kv["title"] ?? deriveTitle(body, path: path),
            tags: parseList(kv["tags"]),
            created: kv["created"].flatMap { iso.date(from: $0) } ?? now,
            updated: kv["updated"].flatMap { iso.date(from: $0) } ?? now,
            body: body,
            extra: extra
        )
    }

    public static func serialize(_ note: Note) -> String {
        let tags = "[" + note.tags.joined(separator: ", ") + "]"
        let extra = note.extra.map { "\($0.key): \($0.rawValue)" }.joined(separator: "\n")
        let extraBlock = extra.isEmpty ? "" : extra + "\n"
        return """
        ---
        id: \(note.id)
        title: \(note.title)
        tags: \(tags)
        created: \(iso.string(from: note.created))
        updated: \(iso.string(from: note.updated))
        \(extraBlock)---
        \(note.body)
        """
    }

    private static func fallback(_ text: String, path: URL) -> Note {
        let now = Date()
        return Note(path: path, id: UUID().uuidString, title: deriveTitle(text, path: path),
                    tags: [], created: now, updated: now, body: text, extra: [])
    }

    private static func deriveTitle(_ body: String, path: URL) -> String {
        for line in body.split(separator: "\n") where line.hasPrefix("# ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return path.deletingPathExtension().lastPathComponent
    }

    private static func parseList(_ raw: String?) -> [String] {
        guard var s = raw else { return [] }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !s.isEmpty else { return [] }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
