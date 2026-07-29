import Foundation

/// YAML frontmatter, read and written PRESERVE-AND-PATCH.
///
/// THE GUIDING RULE: Lore preserves what it does not model; it does not need to
/// understand a property in order to keep it.
///
/// The previous design parsed frontmatter into `Note` and then re-emitted the
/// whole block from that model. That is structurally lossy: anything the model
/// does not understand cannot survive a save. It destroyed YAML block sequences
/// — Obsidian's DEFAULT shape for `aliases`, `cssclasses` and `tags` — because
/// their item lines contain no colon and were skipped, and it rewrote any
/// `created:` it could not parse to today's date.
///
/// Instead, `parse` keeps the ENTIRE original block verbatim on
/// `Note.rawFrontmatter`, and `serialize` starts from that text and surgically
/// replaces only the lines whose modelled value actually changed. Comments,
/// blank lines, key order, indentation, quoting, block sequences and block
/// scalars are copied through byte for byte because nothing ever rewrites them.
public enum Frontmatter {
    /// Keys `Note` models. Everything else is preserved but never interpreted.
    static let modelledKeys = ["id", "title", "tags", "created", "updated"]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - parse

    public static func parse(_ text: String, path: URL) -> Note {
        guard let split = splitBlock(text) else { return fallback(text, path: path) }
        let entries = scan(split.headerLines)
        func entry(_ key: String) -> Entry? { entries.last { $0.key == key } }

        let now = Date()
        let body = split.body
        let extra = entries
            .filter { !modelledKeys.contains($0.key) }
            .map { FrontmatterPair(key: $0.key, rawValue: $0.flattenedValue) }

        return Note(
            path: path,
            id: entry("id").map(\.inlineValue).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
            title: entry("title").map(\.inlineValue).flatMap { $0.isEmpty ? nil : $0 }
                ?? deriveTitle(body, path: path),
            tags: entry("tags").map(list(of:)) ?? [],
            created: entry("created").flatMap { date(from: $0.inlineValue) } ?? now,
            updated: entry("updated").flatMap { date(from: $0.inlineValue) } ?? now,
            body: body,
            extra: extra,
            rawFrontmatter: split.header
        )
    }

    /// Splits `---` fenced frontmatter off the front of a document.
    ///
    /// Line-based rather than substring-based so that an EMPTY block
    /// (`---\n---\n`) is still recognised as frontmatter.
    private static func splitBlock(_ text: String) -> (header: String, headerLines: [String], body: String)? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return nil }
        let headerLines = Array(lines[1..<close])
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (headerLines.joined(separator: "\n"), headerLines, body)
    }

    // MARK: - serialize

    public static func serialize(_ note: Note) -> String {
        guard let raw = note.rawFrontmatter else { return serializeFromModel(note) }

        var lines = raw.isEmpty ? [] : raw.components(separatedBy: "\n")
        let entries = scan(lines)
        var edits: [(range: ClosedRange<Int>, replacement: String)] = []
        var appended: [String] = []

        for key in modelledKeys {
            let existing = entries.last { $0.key == key }
            switch patch(key: key, note: note, entry: existing) {
            case .leave:
                continue
            case .replace(let text):
                if let e = existing { edits.append((e.start...e.end, "\(key): \(text)")) }
                else { appended.append("\(key): \(text)") }
            }
        }

        // Apply back to front so earlier ranges keep their indices.
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            lines.replaceSubrange(edit.range, with: [edit.replacement])
        }
        lines.append(contentsOf: appended)
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + note.body
    }

    private enum Patch {
        /// Leave the original bytes exactly as they are.
        case leave
        /// The value after `key: ` to write.
        case replace(String)
    }

    /// Decides, per modelled key, whether the on-disk text still represents the
    /// model's value. If it does, the original bytes are left alone — that is
    /// what keeps block sequences, quoting and ISO-8601 dates intact. Only a
    /// value that genuinely CHANGED is rewritten, and only that key's lines.
    ///
    /// A key ABSENT from the original is appended only when the model holds
    /// something real to say about it. `id` always qualifies — without it Lore
    /// invents a new identity on every load. A title that is merely derived
    /// from the body heading or the filename, an empty tag list, and a
    /// `created`/`updated` that defaulted to "now" because the file never had
    /// one are all fabrications, and writing them into a user's vault is the
    /// same corruption class this task exists to remove.
    private static func patch(key: String, note: Note, entry: Entry?) -> Patch {
        switch key {
        case "id":
            guard entry?.inlineValue != note.id else { return .leave }
            return .replace(note.id)
        case "title":
            guard let entry else {
                return note.title == deriveTitle(note.body, path: note.path)
                    ? .leave : .replace(note.title)
            }
            return entry.inlineValue == note.title ? .leave : .replace(note.title)
        case "tags":
            guard let entry else { return note.tags.isEmpty ? .leave : .replace(inline(note.tags)) }
            return list(of: entry) == note.tags ? .leave : .replace(inline(note.tags))
        case "created", "updated":
            guard let entry else { return .leave }
            // Unparseable dates are NEVER rewritten: Lore does not corrupt a
            // timestamp it merely failed to understand.
            guard let onDisk = date(from: entry.inlineValue) else { return .leave }
            let model = key == "created" ? note.created : note.updated
            return onDisk == model ? .leave : .replace(dayFormatter.string(from: model))
        default:
            return .leave
        }
    }

    private static func inline(_ values: [String]) -> String {
        "[" + values.joined(separator: ", ") + "]"
    }

    /// Emission for a note that never had a frontmatter block (a brand new note
    /// or a plain markdown file). Nothing to preserve, so the model is the
    /// whole truth.
    private static func serializeFromModel(_ note: Note) -> String {
        let tags = "[" + note.tags.joined(separator: ", ") + "]"
        let extra = note.extra.map { "\($0.key): \($0.rawValue)" }.joined(separator: "\n")
        let extraBlock = extra.isEmpty ? "" : extra + "\n"
        return """
        ---
        id: \(note.id)
        title: \(note.title)
        tags: \(tags)
        created: \(dayFormatter.string(from: note.created))
        updated: \(dayFormatter.string(from: note.updated))
        \(extraBlock)---
        \(note.body)
        """
    }

    // MARK: - scanner

    /// One top-level mapping entry and the exact line range it occupies.
    ///
    /// `end > start` for block sequences (`key:` then `- item` lines) and block
    /// scalars (`key: |` then indented lines) — the shapes the old parser
    /// dropped on the floor.
    struct Entry {
        let key: String
        let inlineValue: String
        let continuation: [String]
        let start: Int
        let end: Int

        /// A single-line rendering for the index's `properties` column. Never
        /// used for serialization.
        var flattenedValue: String {
            guard inlineValue.isEmpty, !continuation.isEmpty else { return inlineValue }
            return "[" + Frontmatter.sequenceItems(continuation).joined(separator: ", ") + "]"
        }
    }

    /// Scans header lines into top-level entries. Comments, blank lines and
    /// anything unrecognised are simply not owned by any entry, which is why
    /// they survive: `serialize` only ever touches lines an entry owns.
    static func scan(_ lines: [String]) -> [Entry] {
        var entries: [Entry] = []
        var i = 0
        while i < lines.count {
            guard let (key, value) = keyValue(lines[i]) else { i += 1; continue }
            var j = i + 1
            while j < lines.count, isContinuation(lines[j]) { j += 1 }
            entries.append(Entry(key: key, inlineValue: value,
                                 continuation: Array(lines[(i + 1)..<j]),
                                 start: i, end: j - 1))
            i = j
        }
        return entries
    }

    /// A top-level `key: value` line, or nil for blanks, comments, sequence
    /// items, indented continuation and anything else we refuse to interpret.
    private static func keyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("- "), trimmed != "-",
              !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
        // Prefer a colon that YAML would accept as a key terminator (followed
        // by a space or end of line) so `title: a: b` keys on the first colon
        // and `url: https://x` does not key on the scheme colon.
        let chars = Array(line)
        var colon: Int?
        for (idx, ch) in chars.enumerated() where ch == ":" {
            if idx == chars.count - 1 || chars[idx + 1] == " " { colon = idx; break }
        }
        guard let c = colon ?? chars.firstIndex(of: ":") else { return nil }
        let key = String(chars[..<c]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, String(chars[(c + 1)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func isContinuation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }   // a blank line ends the entry
        if trimmed.hasPrefix("#") { return false }     // a comment belongs to nobody
        return line.hasPrefix(" ") || line.hasPrefix("\t") || trimmed.hasPrefix("- ") || trimmed == "-"
    }

    // MARK: - values

    /// A list value in either shape: inline `[a, b]` or a block sequence.
    private static func list(of entry: Entry) -> [String] {
        entry.inlineValue.isEmpty ? sequenceItems(entry.continuation) : inlineList(entry.inlineValue)
    }

    static func sequenceItems(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            var t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") || t == "-" else { return nil }
            t = String(t.dropFirst(t == "-" ? 1 : 2)).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : unquoted(t)
        }
    }

    private static func inlineList(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return [] }
        return s.split(separator: ",")
            .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func unquoted(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Lenient date parsing. `yyyy-MM-dd` is what Lore writes; ISO-8601 (with
    /// or without fractional seconds, with or without a zone) is what sync
    /// tools, templater plugins and generators write. Anything else returns nil
    /// and is then left untouched on disk rather than overwritten with today.
    static func date(from raw: String) -> Date? {
        let value = unquoted(raw.trimmingCharacters(in: .whitespaces))
        guard !value.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let d = formatter.date(from: value) { return d }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = [
        "yyyy-MM-dd",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
    ].map { format in
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    // MARK: - no frontmatter

    private static func fallback(_ text: String, path: URL) -> Note {
        let now = Date()
        return Note(path: path, id: UUID().uuidString, title: deriveTitle(text, path: path),
                    tags: [], created: now, updated: now, body: text, extra: [],
                    rawFrontmatter: nil)
    }

    private static func deriveTitle(_ body: String, path: URL) -> String {
        for line in body.split(separator: "\n") where line.hasPrefix("# ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return path.deletingPathExtension().lastPathComponent
    }
}
