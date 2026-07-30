import SwiftUI
import AinkradAppKit

/// Decides whether the caret sits inside an unclosed `[[`, and what has been
/// typed so far — plus, for click-to-open, which `[[…]]` span an offset falls
/// inside. Pure, so the fiddly caret arithmetic is testable without a view host.
///
/// Both functions take CHARACTER offsets, not UTF-16 offsets. `MarkdownEditor`
/// converts at the AppKit boundary, because that is the only place the two
/// index spaces meet.
public enum LinkCompletionContext {
    /// The text between the nearest unclosed `[[` before `caret` and `caret`,
    /// or `nil` when the caret is not inside an open wikilink.
    public static func activePrefix(in text: String, caret: Int) -> String? {
        let chars = Array(text)
        guard caret <= chars.count else { return nil }
        var i = caret - 1
        while i >= 1 {
            if chars[i] == "\n" { return nil }
            // A closing `]]` between here and the caret means the link is done.
            if chars[i] == "]" && chars[i - 1] == "]" { return nil }
            if chars[i] == "[" && chars[i - 1] == "[" {
                return String(chars[(i + 1)..<caret])
            }
            i -= 1
        }
        return nil
    }

    /// The raw target of the `[[…]]` span containing `offset`, or `nil`.
    ///
    /// Raw: any `#heading` or `|alias` syntax is preserved, because
    /// `LinkResolver` — not this function — owns what those mean.
    public static func target(in text: String, at offset: Int) -> String? {
        let chars = Array(text)
        guard offset >= 0, offset <= chars.count else { return nil }

        // Scan back for `[[`, stopping at a line break or a closing `]]`
        // (which would mean the offset sits after a span, not inside one).
        var open: Int?
        var i = offset - 1
        while i >= 1 {
            if chars[i] == "\n" { return nil }
            if chars[i] == "]" && chars[i - 1] == "]" { return nil }
            if chars[i] == "[" && chars[i - 1] == "[" { open = i + 1; break }
            i -= 1
        }
        guard let start = open else { return nil }

        // Scan forward for `]]`, again stopping at a line break or a new `[[`.
        var close: Int?
        var j = offset
        while j + 1 < chars.count {
            if chars[j] == "\n" { return nil }
            if chars[j] == "[" && chars[j + 1] == "[" { return nil }
            if chars[j] == "]" && chars[j + 1] == "]" { close = j; break }
            j += 1
        }
        guard let end = close, end > start else { return nil }
        let raw = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }
}

/// The `[[` completion list. Deliberately dumb: it renders rows and reports
/// picks. Which rows, where it floats and which keys reach it are the text
/// view's business — see `LinkCompletionPanel`.
struct LinkCompletionView: View {
    let matches: [IndexRow]
    let selected: Int
    let tokens: HostThemeTokens
    let onPick: (IndexRow) -> Void

    static let maxRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.prefix(Self.maxRows).enumerated()), id: \.element.path) { pair in
                Button { onPick(pair.element) } label: {
                    HStack {
                        Text(label(for: pair.element)).lineLimit(1)
                            .foregroundStyle(tokens.foreground)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, AinkradSpacing.sm)
                    .padding(.vertical, 4)
                    .background(pair.offset == selected
                                ? tokens.accentPrimary.opacity(0.25) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 260)
        .background(tokens.background)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(tokens.foreground.opacity(0.2)))
    }

    private func label(for row: IndexRow) -> String {
        row.title.isEmpty ? row.path.lastPathComponent : row.title
    }
}
