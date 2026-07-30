import Foundation

/// Which syntax a link was written in. Load-bearing for exactly two decisions
/// that must not be guessed from the target text alone: whether the target is
/// percent-ENCODED (markdown links are, wikilinks never are), and therefore
/// whether a rewritten target must be re-encoded on the way back out.
public enum LinkSyntax: String, Equatable, Hashable, Sendable {
    case wikilink
    case markdown
}

/// One outbound link found in a document.
public struct DocumentLink: Equatable, Sendable {
    /// The target exactly as written, including any `#Heading` or `#^block`
    /// fragment. Never includes the `|display` part.
    ///
    /// Stored verbatim because rename rewriting must reproduce the user's own
    /// syntax: a link written `[[design]]` becomes `[[new-name]]`, never
    /// `[[Projects/New Name.md]]`. For a markdown link this is also the
    /// possibly percent-ENCODED form — see `resolutionTarget`.
    public let rawTarget: String
    public let displayText: String?
    public let isEmbed: Bool
    public let syntax: LinkSyntax

    public init(rawTarget: String, displayText: String? = nil, isEmbed: Bool = false,
                syntax: LinkSyntax = .wikilink) {
        self.rawTarget = rawTarget; self.displayText = displayText; self.isEmbed = isEmbed
        self.syntax = syntax
    }

    /// The target to hand `LinkResolver` — percent-DECODED for a markdown link.
    ///
    /// Obsidian writes `[text](Design%20Doc.md)` for any name containing a
    /// space in markdown-link mode. Resolved raw, that link finds nothing: it
    /// is stored with `target_path NULL`, contributes no backlink, and — worst
    /// — is not rewritten by a rename, so it silently breaks.
    ///
    /// Wikilink targets are returned UNTOUCHED. Obsidian does not encode them,
    /// so a `%` in a `[[…]]` target is a literal `%` in a filename, and
    /// decoding it would resolve the link to the wrong document (or to none).
    public var resolutionTarget: String {
        guard syntax == .markdown, let decoded = rawTarget.removingPercentEncoding
        else { return rawTarget }
        return decoded
    }
}

/// One link together with WHERE its target text sits in the scanned string.
///
/// The offsets are CHARACTER offsets into the string handed to
/// `LinkParser.spans(in:)`, and they cover the raw target only — not the
/// brackets, not the `|display` part, not a markdown link's text. They exist so
/// that `LinkRewriter` can replace a link by RANGE instead of by string search:
/// a whole-document `replacingOccurrences` also mutates every `[[Design]]`
/// written inside a fenced block or inline code, which this parser deliberately
/// excludes from the graph. One scanner, one answer.
public struct LinkSpan: Equatable, Sendable {
    public let link: DocumentLink
    public let targetRange: Range<Int>
    public init(link: DocumentLink, targetRange: Range<Int>) {
        self.link = link; self.targetRange = targetRange
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
        spans(in: body).map(\.link)
    }

    /// Every link, with the character range of its target text.
    ///
    /// The single scan; `links(in:)` is a projection of it. `LinkRewriter`
    /// consumes the ranges so that the rewrite covers EXACTLY the regions the
    /// graph covers — no second, subtly different notion of "inside a code
    /// block" to keep in step.
    public static func spans(in body: String) -> [LinkSpan] {
        var found: [LinkSpan] = []
        var fence: (char: Character, length: Int)?
        // Character offset of the current line's first character. Maintained
        // incrementally: computing it with `distance(from:to:)` per line would
        // make the scan quadratic in document length.
        var lineStart = 0
        // CRLF documents — Windows-authored vaults, sync clients, `core.autocrlf`
        // checkouts — do not split on `"\n"`: Swift treats `"\r\n"` as ONE
        // Character, which is not equal to `"\n"`, so the whole file scans as a
        // single line and every fence goes undetected. Normalising first fixes
        // that, and it is offset-SAFE precisely because `"\r\n"` is one
        // Character: every span offset still indexes the caller's own string.
        let text = body.contains("\r\n")
            ? body.replacingOccurrences(of: "\r\n", with: "\n") : body

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { lineStart += line.count + 1 }   // +1 for the "\n" removed by split
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
            found.append(contentsOf: spans(inLine: String(line), offsetBy: lineStart))
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

    private static func spans(inLine line: String, offsetBy base: Int) -> [LinkSpan] {
        var result: [LinkSpan] = []
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
                    if let span = wikilink(inner, isEmbed: isEmbed, innerStart: i + 2,
                                           offsetBy: base) {
                        result.append(span)
                    }
                    i = close + 2
                    continue
                }
            }
            if chars[i] == "[", let found = markdownLink(chars, from: i, offsetBy: base) {
                result.append(found.span)
                i = found.end
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

    private static func wikilink(_ inner: String, isEmbed: Bool, innerStart: Int,
                                 offsetBy base: Int) -> LinkSpan? {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts[0].trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let display = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        let link = DocumentLink(rawTarget: target,
                                displayText: (display?.isEmpty ?? true) ? nil : display,
                                isEmbed: isEmbed, syntax: .wikilink)
        return LinkSpan(link: link,
                        targetRange: range(of: target, within: String(parts[0]),
                                           startingAt: base + innerStart))
    }

    /// The range the TRIMMED target occupies, given the untrimmed slice it came
    /// from and where that slice starts. Trimming happens before the span is
    /// built, so `[[  Design  ]]` must still point at `Design` and not at the
    /// spaces around it — a rewrite that included them would silently reflow
    /// the user's spacing.
    private static func range(of target: String, within slice: String,
                              startingAt start: Int) -> Range<Int> {
        let leading = slice.prefix { $0 == " " || $0 == "\t" }.count
        return (start + leading)..<(start + leading + target.count)
    }

    /// `[text](target)` — local targets only. A URL with a scheme is not a
    /// vault link and must never enter the graph.
    private static func markdownLink(_ chars: [Character], from start: Int,
                                     offsetBy base: Int)
        -> (span: LinkSpan, end: Int)? {
        var i = start + 1
        while i < chars.count, chars[i] != "]" { i += 1 }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        let text = String(chars[(start + 1)..<i])
        var j = i + 2
        while j < chars.count, chars[j] != ")" { j += 1 }
        guard j < chars.count else { return nil }
        let slice = String(chars[(i + 2)..<j])
        let target = slice.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains("://"), !target.hasPrefix("mailto:") else {
            return nil
        }
        let link = DocumentLink(rawTarget: target, displayText: text.isEmpty ? nil : text,
                                isEmbed: false, syntax: .markdown)
        return (LinkSpan(link: link,
                         targetRange: range(of: target, within: slice,
                                            startingAt: base + i + 2)),
                j + 1)
    }
}
