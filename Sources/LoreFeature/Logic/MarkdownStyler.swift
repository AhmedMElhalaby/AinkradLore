import Foundation

public struct StyleSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(Int), bold, italic, code, link, checkbox(Bool)
    }
    public let range: Range<Int>   // UTF-16 offsets
    public let kind: Kind
}

public enum MarkdownStyler {
    public static func spans(in text: String) -> [StyleSpan] {
        let ns = text as NSString
        var spans: [StyleSpan] = []

        func addMatches(_ pattern: String, _ kind: @escaping (NSTextCheckingResult) -> StyleSpan.Kind?) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let k = kind(m) { spans.append(StyleSpan(range: m.range.location..<(m.range.location+m.range.length), kind: k)) }
            }
        }

        // Headings (line-anchored)
        addMatches("(?m)^(#{1,6})\\s.*$") { m in
            let hashes = ns.substring(with: m.range(at: 1)).count
            return .heading(hashes)
        }
        // Checkboxes
        addMatches("(?m)^\\s*- \\[( |x)\\]") { m in
            .checkbox(ns.substring(with: m.range(at: 1)) == "x")
        }
        addMatches("\\*\\*[^*]+\\*\\*") { _ in .bold }
        addMatches("(?<!\\*)\\*[^*]+\\*(?!\\*)") { _ in .italic }
        addMatches("`[^`]+`") { _ in .code }
        addMatches("\\[[^\\]]+\\]\\([^)]+\\)") { _ in .link }
        return spans
    }
}
