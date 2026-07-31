import Foundation

struct EditResult: Equatable {
    let text: String
    let selection: NSRange
}

/// Typing affordances as pure transforms over `(text, selection)`.
///
/// Pure so they are testable without AppKit, and so the editor's job is
/// reduced to "apply this result as ONE undo group" — multi-step undo on
/// auto-continue is the classic way these features become infuriating.
///
/// Every function returns nil for "not my case", which leaves AppKit's default
/// behaviour completely intact rather than reimplementing it badly.
enum MarkdownEditing {

    /// The list marker at the start of `line`, if any: leading whitespace, the
    /// bullet or number, and any task box.
    struct ListMarker: Equatable {
        let indent: String
        let bullet: String       // "-", "*", or "3."
        let task: Bool
        var continuation: String { indent + nextBullet + (task ? "[ ] " : "") }
        var isOrdered: Bool { Int(bullet.dropLast()) != nil }
        private var nextBullet: String {
            guard let n = Int(bullet.dropLast()) else { return bullet + " " }
            return "\(n + 1). "
        }
        /// The marker's own length, used to detect an EMPTY item.
        var prefixLength: Int { (indent + bullet + " " + (task ? "[ ] " : "")).count }
    }

    static func marker(of line: String) -> ListMarker? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        var bullet = ""
        if let first = rest.first, first == "-" || first == "*" {
            bullet = String(first)
        } else {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, rest.dropFirst(digits.count).first == "." else { return nil }
            bullet = digits + "."
        }
        let afterBullet = rest.dropFirst(bullet.count)
        guard afterBullet.first == " " else { return nil }
        let body = afterBullet.dropFirst()
        let task = body.hasPrefix("[ ] ") || body.hasPrefix("[x] ") || body.hasPrefix("[X] ")
        return ListMarker(indent: indent, bullet: bullet, task: task)
    }

    static func continueList(text: String, selection: NSRange) -> EditResult? {
        let ns = text as NSString
        guard selection.length == 0, selection.location <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = ns.substring(with: lineRange)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard let marker = marker(of: line) else { return nil }

        // An EMPTY item ends the list: remove the marker rather than add another.
        if line.count <= marker.prefixLength {
            let removal = NSRange(location: lineRange.location, length: line.count)
            let updated = ns.replacingCharacters(in: removal, with: "")
            return EditResult(text: updated,
                              selection: NSRange(location: lineRange.location, length: 0))
        }

        let insertion = "\n" + marker.continuation
        let updated = ns.replacingCharacters(
            in: NSRange(location: selection.location, length: 0), with: insertion)
        return EditResult(text: updated,
                          selection: NSRange(location: selection.location + insertion.count,
                                             length: 0))
    }
}

extension MarkdownEditing {

    /// One indent step. Two spaces, matching what `continueList` preserves.
    static let indentUnit = "  "

    /// Indents (`by: 1`) or outdents (`by: -1`) the list item under the caret.
    ///
    /// Returns nil when the caret is not in a list item, so Tab keeps its
    /// normal meaning everywhere else. Outdenting at column zero returns the
    /// text UNCHANGED rather than nil — the keystroke was meaningful, it simply
    /// had nowhere to go, and swallowing it is better than inserting a tab into
    /// a list.
    static func indent(text: String, selection: NSRange, by delta: Int) -> EditResult? {
        let ns = text as NSString
        guard selection.location <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = ns.substring(with: lineRange)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard let marker = marker(of: line) else { return nil }

        var indentText = marker.indent
        if delta > 0 {
            indentText += indentUnit
        } else {
            guard indentText.count >= indentUnit.count else {
                return EditResult(text: text, selection: selection)
            }
            indentText.removeLast(indentUnit.count)
        }

        // An ordered item that changes level restarts at 1: keeping "2." after
        // a nest makes the new sublist start at two.
        let body = line.dropFirst(marker.indent.count + marker.bullet.count)
        let bullet = marker.isOrdered ? "1." : marker.bullet
        let rebuilt = indentText + bullet + body

        let replaced = NSRange(location: lineRange.location, length: (line as NSString).length)
        let updated = ns.replacingCharacters(in: replaced, with: rebuilt)
        let shift = (rebuilt as NSString).length - (line as NSString).length
        return EditResult(text: updated,
                          selection: NSRange(location: max(lineRange.location,
                                                           selection.location + shift),
                                             length: 0))
    }
}

extension MarkdownEditing {

    static let pairs: [String: String] = ["[": "]", "(": ")", "`": "`", "\"": "\""]

    /// Wraps the selection in `delimiter`, or unwraps it if it is already
    /// wrapped. One keystroke toggling both ways is what people expect from
    /// Cmd-B; an "always add" version produces `****bold****` within seconds.
    static func toggleWrap(text: String, selection: NSRange, with delimiter: String) -> EditResult {
        let ns = text as NSString
        let d = (delimiter as NSString).length
        let before = NSRange(location: selection.location - d, length: d)
        let after = NSRange(location: selection.location + selection.length, length: d)

        if before.location >= 0, after.location + after.length <= ns.length,
           ns.substring(with: before) == delimiter, ns.substring(with: after) == delimiter {
            let whole = NSRange(location: before.location,
                                length: d + selection.length + d)
            let inner = ns.substring(with: selection)
            return EditResult(text: ns.replacingCharacters(in: whole, with: inner),
                              selection: NSRange(location: before.location,
                                                 length: selection.length))
        }

        let inner = ns.substring(with: selection)
        let wrapped = delimiter + inner + delimiter
        return EditResult(text: ns.replacingCharacters(in: selection, with: wrapped),
                          selection: NSRange(location: selection.location + d,
                                             length: selection.length))
    }

    /// Auto-pairing. Returns nil for a character that is not a pair opener or
    /// closer, leaving normal typing completely untouched.
    static func autoPair(text: String, selection: NSRange, typing: String) -> EditResult? {
        let ns = text as NSString

        // Typing a closer that is already there: step over it.
        if pairs.values.contains(typing), selection.length == 0,
           selection.location < ns.length,
           ns.substring(with: NSRange(location: selection.location, length: 1)) == typing {
            return EditResult(text: text,
                              selection: NSRange(location: selection.location + 1, length: 0))
        }

        guard let closer = pairs[typing] else { return nil }

        // A selection is SURROUNDED, never replaced — replacing it would
        // silently destroy text the user had chosen.
        if selection.length > 0 {
            let inner = ns.substring(with: selection)
            return EditResult(text: ns.replacingCharacters(in: selection,
                                                           with: typing + inner + closer),
                              selection: NSRange(location: selection.location + 1,
                                                 length: selection.length))
        }

        return EditResult(text: ns.replacingCharacters(in: selection, with: typing + closer),
                          selection: NSRange(location: selection.location + 1, length: 0))
    }
}
