import Foundation

/// `$inline$` and `$$block$$` math.
///
/// ## What this deliberately is not
///
/// It is not a TeX renderer, and it does not pretend to be one. Obsidian ships
/// MathJax; there is no equivalent for AppKit that does not drag in a web view,
/// and the one thing this editor may never do is CHANGE THE TEXT — every
/// offset the index, the link graph and the MCP tools hold is measured against
/// it. That rules out the whole substitution family: `\alpha` cannot become
/// `α`, because `α` is a character the document does not contain.
///
/// What CAN be rendered correctly with attributes alone is scripts:
/// `x^2` becomes x² by shrinking the `2` and lifting its baseline, with the `^`
/// collapsed — no character added, none removed, and the result is exactly what
/// the expression means.
///
/// ## So the rule is all-or-nothing per expression
///
/// An expression is rendered only when EVERY part of it can be. Anything
/// containing a command this cannot honour is left as source and merely tinted,
/// so it still reads as mathematics rather than as prose. Half-rendering —
/// `α` shown but `\frac{a}{b}` left raw inside the same expression — would be
/// worse than either, because the reader could no longer tell which parts are
/// notation and which are content.
enum MarkdownMath {

    struct Span: Equatable {
        /// The whole expression, delimiters included.
        let range: Range<Int>
        /// Between the delimiters.
        let content: Range<Int>
        let isBlock: Bool
        /// Whether every part of this expression can be rendered exactly. When
        /// false the source is shown, tinted, and nothing is collapsed.
        let isRenderable: Bool
        /// `^`/`_` and any braces, to collapse. Empty unless renderable.
        let markers: [Range<Int>]
        /// Script content, with whether it is raised or lowered.
        let scripts: [(range: Range<Int>, isSuperscript: Bool)]

        static func == (a: Span, b: Span) -> Bool {
            a.range == b.range && a.content == b.content && a.isBlock == b.isBlock
                && a.isRenderable == b.isRenderable && a.markers == b.markers
                && a.scripts.map(\.range) == b.scripts.map(\.range)
                && a.scripts.map(\.isSuperscript) == b.scripts.map(\.isSuperscript)
        }
    }

    /// Finds every math expression in `text`.
    ///
    /// - Parameter isSuppressed: answers whether an offset sits inside a code
    ///   region. A `$` in a shell fence is a variable, not mathematics, and
    ///   `$PATH` would otherwise open an expression that runs to the next `$`
    ///   in the file.
    static func spans(in text: NSString,
                      isSuppressed: (Int) -> Bool = { _ in false }) -> [Span] {
        var out: [Span] = []
        var index = 0
        while index < text.length {
            guard text.character(at: index) == 0x24, !isSuppressed(index) else {
                index += 1
                continue
            }
            let isBlock = index + 1 < text.length && text.character(at: index + 1) == 0x24
            let width = isBlock ? 2 : 1
            guard let close = closingDelimiter(from: index + width, width: width,
                                               isBlock: isBlock, in: text) else {
                index += 1
                continue
            }
            let content = (index + width)..<close
            let whole = index..<(close + width)
            if let rendered = render(content: content, in: text) {
                out.append(Span(range: whole, content: content, isBlock: isBlock,
                                isRenderable: true,
                                markers: rendered.markers, scripts: rendered.scripts))
            } else {
                out.append(Span(range: whole, content: content, isBlock: isBlock,
                                isRenderable: false, markers: [], scripts: []))
            }
            index = close + width
        }
        return out
    }

    /// The matching closing delimiter, or `nil`.
    ///
    /// The two rules that keep prose out: an expression may not be empty, and
    /// its closing delimiter may not be preceded by a space. Together they are
    /// what stops `costs $5 and $7` from reading as the expression `5 and ` —
    /// the candidate closer is preceded by a space, so it is rejected, and the
    /// scan moves on rather than swallowing the line.
    ///
    /// An INLINE expression may not cross a line either. A stray `$` in prose
    /// would otherwise reach for one three paragraphs down and tint everything
    /// between.
    private static func closingDelimiter(from start: Int, width: Int, isBlock: Bool,
                                         in text: NSString) -> Int? {
        var index = start
        while index < text.length {
            let unit = text.character(at: index)
            if !isBlock, unit == 0x0A || unit == 0x0D { return nil }
            if unit == 0x5C { index += 2; continue }               // \$ is a literal
            if unit == 0x24 {
                let matches = width == 1
                    || (index + 1 < text.length && text.character(at: index + 1) == 0x24)
                if matches, index > start,
                   !isSpace(text.character(at: index - 1)) { return index }
            }
            index += 1
        }
        return nil
    }

    /// Whether this content can be rendered exactly, and how.
    ///
    /// `nil` means "leave it as source". Everything not explicitly handled
    /// lands there — a backslash command, a bracket, anything unfamiliar — so
    /// the failure direction is always "show what the author wrote".
    private static func render(content: Range<Int>, in text: NSString)
        -> (markers: [Range<Int>], scripts: [(range: Range<Int>, isSuperscript: Bool)])? {
        guard content.lowerBound < content.upperBound else { return nil }
        var markers: [Range<Int>] = []
        var scripts: [(range: Range<Int>, isSuperscript: Bool)] = []
        var index = content.lowerBound
        var sawScript = false

        while index < content.upperBound {
            let unit = text.character(at: index)
            if unit == 0x5E || unit == 0x5F {                       // ^ _
                let isSuper = unit == 0x5E
                guard index + 1 < content.upperBound else { return nil }
                markers.append(index..<(index + 1))
                let next = index + 1
                if text.character(at: next) == 0x7B {                // {
                    guard let close = matchingBrace(from: next, limit: content.upperBound,
                                                    in: text) else { return nil }
                    guard close > next + 1 else { return nil }       // `^{}` renders nothing
                    markers.append(next..<(next + 1))
                    markers.append(close..<(close + 1))
                    scripts.append(((next + 1)..<close, isSuper))
                    index = close + 1
                } else {
                    guard isPlain(text.character(at: next)) else { return nil }
                    scripts.append((next..<(next + 1), isSuper))
                    index = next + 1
                }
                sawScript = true
                continue
            }
            // Anything that is not a script and not plain content — a
            // backslash command above all — means this expression is not one
            // this renderer can honour.
            guard isPlain(unit) else { return nil }
            index += 1
        }
        // An expression with no scripts has nothing to render, so rendering it
        // would only hide its `$` delimiters and leave the text looking like
        // prose. Better to keep the delimiters and tint it.
        // Written out rather than as a ternary: `sawScript ? (markers, scripts)
        // : nil` made Swift's type checker give up entirely — "failed to
        // produce diagnostic for expression", which is a compiler crash and
        // says nothing about the cause. A labelled tuple inside an optional
        // inside a ternary is apparently one inference step too many.
        guard sawScript else { return nil }
        return (markers: markers, scripts: scripts)
    }

    private static func matchingBrace(from open: Int, limit: Int, in text: NSString) -> Int? {
        var depth = 0
        var index = open
        while index < limit {
            switch text.character(at: index) {
            case 0x7B: depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// Characters an expression may contain and still be rendered exactly:
    /// letters, digits, spaces and ordinary arithmetic. Deliberately a short
    /// allow-list — every character NOT on it sends the expression down the
    /// "show the source" path, which is always safe.
    private static func isPlain(_ unit: unichar) -> Bool {
        // Written as a switch rather than one boolean chain: the chain made
        // Swift's type checker give up outright ("failed to produce diagnostic
        // for expression"), which is a compiler crash rather than a build
        // error and says nothing about what is wrong.
        switch unit {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39:      // A-Z a-z 0-9
            return true
        case 0x20:                                        // space
            return true
        case 0x2B, 0x2D, 0x2A, 0x2F, 0x3D:                // + - * / =
            return true
        case 0x28, 0x29, 0x2E, 0x2C:                      // ( ) . ,
            return true
        default:
            return false
        }
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}
