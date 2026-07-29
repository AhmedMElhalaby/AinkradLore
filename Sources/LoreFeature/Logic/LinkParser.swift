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
        var inFence = false
        var fenceMarker = ""

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceOpener(trimmed) {
                if inFence, trimmed.hasPrefix(fenceMarker) { inFence = false; fenceMarker = "" }
                else if !inFence { inFence = true; fenceMarker = marker }
                continue
            }
            guard !inFence else { continue }
            found.append(contentsOf: links(inLine: String(line)))
        }
        return found
    }

    /// ``` or ~~~ (three or more), per CommonMark.
    private static func fenceOpener(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) { return marker }
        return nil
    }

    private static func links(inLine line: String) -> [DocumentLink] {
        var result: [DocumentLink] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            // Inline code spans swallow everything to the closing backtick.
            if chars[i] == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != "`" { j += 1 }
                i = j < chars.count ? j + 1 : chars.count
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
