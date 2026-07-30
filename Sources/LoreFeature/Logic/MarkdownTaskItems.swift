import Foundation

/// One GFM task-list checkbox, located precisely enough to toggle.
///
/// `markerRangeUTF16` covers EXACTLY the one character between the brackets —
/// the `" "` of `[ ]` or the `x` of `[x]` — never the brackets themselves. That
/// is what makes a toggle a one-character replacement rather than a rewrite of
/// the item, which in turn is what lets it ride the editor's ordinary edit path
/// (one undo step, one dirty mark, one debounced autosave) instead of needing a
/// write of its own.
public struct TaskItem: Equatable, Sendable {
    public let isChecked: Bool
    /// UTF-16 offsets into the string the owning `MarkdownDocumentModel`
    /// describes. Length is always 1.
    public let markerRangeUTF16: NSRange

    public init(isChecked: Bool, markerRangeUTF16: NSRange) {
        self.isChecked = isChecked
        self.markerRangeUTF16 = markerRangeUTF16
    }
}

/// The one place the shape of a checkbox marker is known.
///
/// Two callers need it and they hold DIFFERENT strings: the model validates
/// against its own `fullText`, and the editor validates against the live text
/// under the caret, whose offsets may have moved since the parse that produced
/// the span. Expressing the check once, parameterised by the string, is what
/// keeps those two answers from drifting — the drift is exactly the failure
/// mode that would toggle an arbitrary character of a user's note.
enum TaskCheckbox {
    /// The marker character's range, given the `[x]` bracket span a
    /// `.checkbox` style span covers — but ONLY if `text` really still holds a
    /// bracketed marker there.
    ///
    /// Every part is verified against `text` rather than trusted from
    /// arithmetic: the span must be three units long, in bounds, opened by `[`,
    /// closed by `]`, and hold one of the three legal marker spellings between
    /// them. A span that fails any of these describes a string that has moved
    /// on, and the honest answer is `nil` — no toggle — not a guess.
    static func markerRange(forBracketSpan span: Range<Int>, in text: NSString) -> NSRange? {
        guard span.count == 3, span.lowerBound >= 0, span.upperBound <= text.length else {
            return nil
        }
        guard text.character(at: span.lowerBound) == 0x5B,        // [
              text.character(at: span.upperBound - 1) == 0x5D     // ]
        else { return nil }
        let marker = NSRange(location: span.lowerBound + 1, length: 1)
        guard toggled(text.substring(with: marker)) != nil else { return nil }
        return marker
    }

    /// What the marker character becomes when clicked, or `nil` when the
    /// character is not a marker at all.
    static func toggled(_ current: String) -> String? {
        switch current {
        case " ": return "x"
        case "x", "X": return " "
        default: return nil
        }
    }
}

extension MarkdownDocumentModel {

    /// Every toggleable task checkbox, in document order.
    ///
    /// Derived from the `.checkbox` style spans the single AST walk already
    /// produced — NOT from a second scan. The walk knows a `- [ ]` inside a
    /// fenced code block is not a list item at all (the parser never made one),
    /// so a fence's lookalikes are absent here for the same reason they are
    /// absent from the styling.
    ///
    /// A malformed item contributes nothing: `- [] a` and `- [y] a` are not
    /// task items to swift-markdown, so they carry no `.checkbox` span, and an
    /// item whose span no longer matches the text is dropped by
    /// `TaskCheckbox.markerRange`. They still style as ordinary list items.
    public var taskItems: [TaskItem] {
        let ns = fullText as NSString
        return astStyleSpans.compactMap { span in
            guard case .checkbox(let isChecked) = span.kind,
                  let marker = TaskCheckbox.markerRange(forBracketSpan: span.range, in: ns)
            else { return nil }
            return TaskItem(isChecked: isChecked, markerRangeUTF16: marker)
        }
    }

    /// `fullText` with `item`'s marker character flipped.
    ///
    /// - Parameter fullText: the string to apply the toggle to. Passed in
    ///   rather than taken from `self` because the caller may hold a string
    ///   that has moved on since this model was parsed — the editor's spans lag
    ///   the live text by up to one styling debounce. The marker is re-read
    ///   from THIS string and the toggle is refused (the string is returned
    ///   unchanged) if what sits there is not `" "`, `"x"` or `"X"`. Styling
    ///   the wrong character is cosmetic; toggling one edits a note.
    ///
    /// The BRACKETS are re-read too, not just the marker character, because the
    /// marker alphabet is not distinctive enough on its own: `"x"` and `"X"`
    /// are ordinary letters, so a stale offset landing in prose has a real
    /// chance of finding one and "toggling" a word. Requiring `[`·marker·`]`
    /// makes an accidental match implausible rather than merely unlikely.
    public func toggle(_ item: TaskItem, in fullText: String) -> String {
        let ns = fullText as NSString
        let range = item.markerRangeUTF16
        guard range.length == 1, range.location >= 1,
              NSMaxRange(range) < ns.length,
              let marker = TaskCheckbox.markerRange(
                  forBracketSpan: (range.location - 1)..<(range.location + 2), in: ns),
              let replacement = TaskCheckbox.toggled(ns.substring(with: marker))
        else { return fullText }
        return ns.replacingCharacters(in: marker, with: replacement)
    }
}
