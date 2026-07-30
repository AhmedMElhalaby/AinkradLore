import Foundation

/// Which markers are hidden, given where the selection is.
///
/// Pure and text-view-free on purpose: this is the rule that decides what the
/// user sees, and it is asserted directly rather than through a view host.
enum MarkdownReveal {

    /// Blocks, delimited by blank lines. Deliberately cheap: this runs on every
    /// selection change, and a full AST walk per caret move is exactly the lag
    /// this milestone exists to avoid.
    ///
    /// Scans in UTF-16 units but counts LINE TERMINATORS, not units: "\r\n" is
    /// one terminator (two units), and a lone "\r" or lone "\n" is one
    /// terminator each. A blank line is two consecutive terminators with
    /// nothing but spaces/tabs between them — this is what makes a CRLF
    /// document's ordinary single line breaks NOT count as a blank line.
    static func blocks(in text: String) -> [Range<Int>] {
        let ns = text as NSString
        var result: [Range<Int>] = []
        var start = 0
        var index = 0
        var terminatorRun = 0

        while index < ns.length {
            let unit = ns.character(at: index)
            if unit == 0x0D || unit == 0x0A {
                // Consume a full terminator: a lone unit, or a "\r\n" pair.
                var terminatorEnd = index + 1
                if unit == 0x0D, terminatorEnd < ns.length, ns.character(at: terminatorEnd) == 0x0A {
                    terminatorEnd += 1
                }
                terminatorRun += 1
                if terminatorRun >= 2 {
                    if terminatorEnd > start { result.append(start..<terminatorEnd) }
                    start = terminatorEnd
                    terminatorRun = 0
                }
                index = terminatorEnd
            } else if unit != 0x20 && unit != 0x09 {
                terminatorRun = 0
                index += 1
            } else {
                index += 1
            }
        }
        if start < ns.length { result.append(start..<ns.length) }
        return result.isEmpty ? [0..<max(ns.length, 0)] : result
    }

    /// The marker ranges that must be COLLAPSED for this selection.
    static func hiddenMarkers(spans: [StyleSpan], selection: NSRange,
                              blocks: [Range<Int>]) -> [Range<Int>] {
        let selected = selection.location..<(selection.location + max(selection.length, 0))
        // A block is revealed when the selection touches it. `<=` on both ends
        // so a caret resting exactly at a boundary reveals rather than flickers.
        let revealed = blocks.filter {
            selected.lowerBound <= $0.upperBound && $0.lowerBound <= selected.upperBound
        }
        return spans.compactMap { span in
            guard case .marker = span.kind else { return nil }
            let inRevealed = revealed.contains {
                span.range.lowerBound >= $0.lowerBound && span.range.upperBound <= $0.upperBound
            }
            return inRevealed ? nil : span.range
        }
    }
}
