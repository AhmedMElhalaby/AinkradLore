import Foundation

/// One outbound link found in a document.
public struct DocumentLink: Equatable, Sendable {
    /// The target exactly as written, including any `#Heading` or `#^block`
    /// fragment. Never includes the `|display` part.
    ///
    /// Stored verbatim because rename rewriting must reproduce the user's own
    /// syntax: a link written `[[design]]` becomes `[[new-name]]`, never
    /// `[[Projects/New Name.md]]`.
    public let rawTarget: String
    public let displayText: String?
    public let isEmbed: Bool

    public init(rawTarget: String, displayText: String? = nil, isEmbed: Bool = false) {
        self.rawTarget = rawTarget; self.displayText = displayText; self.isEmbed = isEmbed
    }
}

/// Extracts links from markdown body text.
///
/// Deliberately code-aware: a `[[link]]` inside a fenced block or inline code
/// is documentation ABOUT a link, not a link. `MarkdownEngine.outline(of:)`
/// has this gap and produces phantom headings from `#` comments in code; a
/// phantom LINK is worse, because it appears in another document's backlinks
/// and survives into rename rewriting.
public enum LinkParser {
    public static func links(in body: String) -> [DocumentLink] {
        var found: [DocumentLink] = []
        var fence: (char: Character, length: Int)?

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingSpaceCount(line)
            if let open = fence {
                // A closing fence must use the same character, be at least as
                // long as the opener, be indented no more than 3 spaces, and
                // (per CommonMark) carry no info string of its own.
                if indent <= 3, let run = fenceRun(trimmed, char: open.char),
                   run.length >= open.length, run.rest.isEmpty {
                    fence = nil
                }
                continue
            }
            if indent <= 3, let run = fenceOpener(trimmed) {
                fence = (run.char, run.length)
                continue
            }
            found.append(contentsOf: links(inLine: String(line)))
        }
        return found
    }

    private static func leadingSpaceCount(_ line: Substring) -> Int {
        var count = 0
        for char in line {
            if char == " " { count += 1 } else { break }
        }
        return count
    }

    /// A fence line is a run of 3+ backticks or 3+ tildes, per CommonMark.
    /// Returns the run's character, its length, and whatever follows it
    /// (the info string, if any).
    private static func fenceRun(_ trimmed: String, char: Character) -> (length: Int, rest: Substring)? {
        guard trimmed.first == char else { return nil }
        let run = trimmed.prefix(while: { $0 == char })
        guard run.count >= 3 else { return nil }
        return (run.count, trimmed[run.endIndex...])
    }

    /// ``` or ~~~ (three or more), per CommonMark. An info string (e.g.
    /// ```swift) is permitted after the opener only.
    private static func fenceOpener(_ trimmed: String) -> (char: Character, length: Int)? {
        for marker: Character in ["`", "~"] {
            if let run = fenceRun(trimmed, char: marker) { return (marker, run.length) }
        }
        return nil
    }

    private static func links(inLine line: String) -> [DocumentLink] {
        var result: [DocumentLink] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            // Inline code spans swallow everything to the closing backtick —
            // but only when a closer actually exists later on the line. A
            // dangling/unbalanced backtick is ordinary text, not code, so
            // scanning must continue past it rather than eating the rest of
            // the line (which would silently drop any link that follows).
            if chars[i] == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != "`" { j += 1 }
                if j < chars.count {
                    i = j + 1
                    continue
                }
                i += 1
                continue
            }
            if chars[i] == "[", i + 1 < chars.count, chars[i + 1] == "[" {
                let isEmbed = i > 0 && chars[i - 1] == "!"
                if let close = closingBrackets(chars, from: i + 2) {
                    let inner = String(chars[(i + 2)..<close])
                    if let link = wikilink(inner, isEmbed: isEmbed) { result.append(link) }
                    i = close + 2
                    continue
                }
            }
            if chars[i] == "[", let link = markdownLink(chars, from: i) {
                result.append(link.link)
                i = link.end
                continue
            }
            i += 1
        }
        return result
    }

    private static func closingBrackets(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "]" && chars[i + 1] == "]" { return i }
            i += 1
        }
        return nil
    }

    private static func wikilink(_ inner: String, isEmbed: Bool) -> DocumentLink? {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts[0].trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let display = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        return DocumentLink(rawTarget: target,
                            displayText: (display?.isEmpty ?? true) ? nil : display,
                            isEmbed: isEmbed)
    }

    /// `[text](target)` — local targets only. A URL with a scheme is not a
    /// vault link and must never enter the graph.
    private static func markdownLink(_ chars: [Character], from start: Int)
        -> (link: DocumentLink, end: Int)? {
        var i = start + 1
        while i < chars.count, chars[i] != "]" { i += 1 }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        let text = String(chars[(start + 1)..<i])
        var j = i + 2
        while j < chars.count, chars[j] != ")" { j += 1 }
        guard j < chars.count else { return nil }
        let target = String(chars[(i + 2)..<j]).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains("://"), !target.hasPrefix("mailto:") else {
            return nil
        }
        return (DocumentLink(rawTarget: target, displayText: text.isEmpty ? nil : text,
                             isEmbed: false), j + 1)
    }
}
