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
