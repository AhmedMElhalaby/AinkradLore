import SwiftUI
import AinkradAppKit

/// Decides whether the caret sits inside an unclosed `[[`, what has been typed
/// so far, which `[[…]]` span an offset falls inside, and what text a picked
/// row must insert to be findable again. Pure, so all the fiddly arithmetic is
/// testable without a view host.
///
/// The offset-taking entry points speak CHARACTER offsets, not UTF-16 offsets.
/// `MarkdownEditor` converts at the AppKit boundary, because that is the only
/// place the two index spaces meet.
public enum LinkCompletionContext {
    /// The text between the nearest unclosed `[[` before `caret` and `caret`,
    /// or `nil` when the caret is not inside an open wikilink.
    public static func activePrefix(in text: String, caret: Int) -> String? {
        guard caret >= 0,
              let index = text.index(text.startIndex, offsetBy: caret,
                                     limitedBy: text.endIndex) else { return nil }
        return activePrefix(in: text, caret: index)
    }

    /// The real implementation, in `String.Index` space.
    ///
    /// Index-based rather than `Array(text)`-based because this runs on EVERY
    /// keystroke: materialising the whole document as a `[Character]` per
    /// keypress made the cost of typing grow with document length for no
    /// reason. This walks backwards from the caret and stops at the line start,
    /// so the cost is the length of the current line, not of the document.
    static func activePrefix(in text: String, caret: String.Index) -> String? {
        var i = caret
        while i > text.startIndex {
            let prev = text.index(before: i)
            let c = text[prev]
            if c == "\n" { return nil }
            if prev > text.startIndex {
                let before = text[text.index(before: prev)]
                // A closing `]]` between here and the caret means the link is done.
                if c == "]" && before == "]" { return nil }
                if c == "[" && before == "[" { return String(text[i..<caret]) }
            }
            i = prev
        }
        return nil
    }

    /// The raw target of the `[[…]]` span containing `offset`, or `nil`.
    ///
    /// Raw: any `#heading` or `|alias` syntax is preserved, because
    /// `LinkResolver` — not this function — owns what those mean. Use
    /// `documentName(of:)` for the part that names a document.
    public static func target(in text: String, at offset: Int) -> String? {
        let chars = Array(text)
        guard offset >= 0, offset <= chars.count else { return nil }
        let start = normalised(offset, in: chars)

        // Scan back for `[[`, stopping at a line break or a closing `]]`
        // (which would mean the offset sits after a span, not inside one).
        var open: Int?
        var i = start - 1
        while i >= 1 {
            if chars[i] == "\n" { return nil }
            if chars[i] == "]" && chars[i - 1] == "]" { return nil }
            if chars[i] == "[" && chars[i - 1] == "[" { open = i + 1; break }
            i -= 1
        }
        guard let from = open else { return nil }

        // Scan forward for `]]`, again stopping at a line break or a new `[[`.
        var close: Int?
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "\n" { return nil }
            if chars[j] == "[" && chars[j + 1] == "[" { return nil }
            if chars[j] == "]" && chars[j + 1] == "]" { close = j; break }
            j += 1
        }
        guard let to = close, to > from else { return nil }
        let raw = String(chars[from..<to]).trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }

    /// Pulls a click that landed ON the `[[` or `]]` glyphs into the span's
    /// interior, so the whole visible link is clickable rather than only its
    /// inner text — the brackets are the most obviously "link-ish" part of it.
    private static func normalised(_ offset: Int, in chars: [Character]) -> Int {
        if offset + 1 < chars.count, chars[offset] == "[", chars[offset + 1] == "[" {
            return offset + 2                     // before the opening `[[`
        }
        if offset > 0, offset < chars.count, chars[offset - 1] == "[", chars[offset] == "[" {
            return offset + 1                     // between the two `[`
        }
        if offset > 0, offset < chars.count, chars[offset - 1] == "]", chars[offset] == "]" {
            return offset - 1                     // between the two `]`
        }
        return offset
    }

    /// The part of a raw target that names a DOCUMENT: alias segment and any
    /// `#heading` fragment removed.
    ///
    /// `LinkResolver.basename` strips the fragment but not the alias, so
    /// `Design|why` would otherwise be looked up — and created — verbatim.
    public static func documentName(of rawTarget: String) -> String {
        var target = rawTarget
        if let pipe = target.firstIndex(of: "|") { target = String(target[..<pipe]) }
        return LinkResolver.basename(of: target)
    }

    /// Characters that change what a target MEANS: `#` starts a fragment, `|`
    /// starts an alias, brackets end or restart the span, `/` turns the target
    /// into a path suffix.
    private static let unusableInTarget: Set<Character> = ["#", "|", "[", "]", "/"]

    /// The text to insert for a picked row, VERIFIED against the resolver.
    ///
    /// Picking a document from a list must never produce a link that fails to
    /// find it — or worse, one that finds a different document. Three things
    /// break a target that merely looks reasonable, and only the first is
    /// visible in the row itself:
    ///
    ///  - punctuation: `Sprint #3` truncates to `Sprint` at the fragment marker;
    ///  - whitespace: `LinkResolver` keys on the RAW title, so a title stored as
    ///    `"Design "` is not found by `Design` — and it cannot be found by
    ///    `Design ` either, because `basename` trims;
    ///  - ambiguity: a title equal to some OTHER document's filename resolves to
    ///    whichever has the shorter path, which may not be this row.
    ///
    /// None of those are decidable from the row alone, so this does not guess.
    /// It proposes candidates in order of how they read to a human — title,
    /// filename, vault-relative path — and returns the first that resolves back
    /// to this exact document. The path candidate is the backstop: it is what
    /// `LinkResolver` disambiguates by suffix, so it survives ambiguity by
    /// construction.
    ///
    /// - Parameters:
    ///   - relativePath: `row`'s path relative to the vault root, without the
    ///     extension (`Projects/Design`). Empty when there is no vault root.
    ///   - resolves: the resolver, injected so this stays pure and testable.
    public static func insertableTarget(for row: IndexRow, relativePath: String,
                                        resolves: (String) -> URL?) -> String {
        var candidates: [String] = []
        let title = row.title.trimmingCharacters(in: .whitespaces)
        if isUsableTarget(title) { candidates.append(title) }
        let filename = row.path.deletingPathExtension().lastPathComponent
        if isUsableTarget(filename) { candidates.append(filename) }
        // The path candidate is exempt from the `/` rule — a `/` is the whole
        // point of it — but not from the rest.
        if !relativePath.isEmpty, isUsablePathTarget(relativePath) {
            candidates.append(relativePath)
        }

        let wanted = row.path.standardizedFileURL.path
        for candidate in candidates
        where resolves(candidate)?.standardizedFileURL.path == wanted {
            return candidate
        }

        // Nothing round-trips: the document is unreachable by any spelling we
        // can write (an unindexed row, or a filename carrying link
        // punctuation). The fallback used to be `candidates.last` returned
        // UNVERIFIED — the most specific candidate, but with no check that it
        // does not resolve to some OTHER document. That is the precise failure
        // the verification above exists to prevent, reintroduced one line below
        // it.
        //
        // So the fallback is verified too, against a weaker bar: a candidate
        // that resolves to NOTHING. A dead link is visibly dead — it shows as
        // unresolved, the backlinks panel lists it, and "Create note" fixes it.
        // A link that silently opens a different note is a wrong answer wearing
        // a right answer's clothes, and nothing in the UI ever flags it. Most
        // specific first, because a path target is the one the resolver
        // disambiguates by suffix and so the one most likely to be dead for the
        // right reason.
        for candidate in candidates.reversed() where resolves(candidate) == nil {
            return candidate
        }
        // Every spelling resolves, and every one resolves elsewhere. There is
        // no honest answer left to write, so this returns the most specific
        // candidate: a path target survives ambiguity by construction and is
        // the likeliest to become correct once the vault changes.
        return candidates.last ?? filename
    }

    /// The store-blind form, for callers with no resolver — it can only apply
    /// the punctuation rule, so it is NOT round-trip guaranteed.
    public static func insertableTarget(for row: IndexRow) -> String {
        let title = row.title.trimmingCharacters(in: .whitespaces)
        return isUsableTarget(title) ? title
            : row.path.deletingPathExtension().lastPathComponent
    }

    /// A trailing `.md` is excluded too: `basename` strips it, so a title of
    /// `Notes.md` would resolve to `Notes`.
    static func isUsableTarget(_ candidate: String) -> Bool {
        !candidate.isEmpty
            && candidate.allSatisfy { !unusableInTarget.contains($0) }
            && !candidate.lowercased().hasSuffix(".md")
    }

    /// As `isUsableTarget`, but `/` is allowed — a path target is meant to be
    /// read as a path suffix.
    static func isUsablePathTarget(_ candidate: String) -> Bool {
        isUsableTarget(candidate.replacingOccurrences(of: "/", with: ""))
            && !candidate.lowercased().hasSuffix(".md")
    }
}

/// Which rows the completion list is offering, and which one is highlighted.
///
/// A value type with no AppKit in it, so the two rules that are easy to get
/// wrong — the highlight resets when the matches change, and the arrow keys
/// clamp at the ends rather than wrapping — are unit-testable without a window.
struct LinkCompletionSelection: Equatable {
    private(set) var matches: [IndexRow] = []
    private(set) var index = 0

    /// Rows the list can actually show. The highlight may never point past them.
    var visibleCount: Int { min(matches.count, LinkCompletionView.maxRows) }

    var current: IndexRow? { index < matches.count ? matches[index] : nil }

    /// A changed match set resets the highlight to the top: after another
    /// keystroke the row at the old index is a different document, and silently
    /// leaving the highlight there is how a user accepts the wrong note.
    mutating func update(to rows: [IndexRow]) {
        if rows != matches { matches = rows; index = 0 }
        index = min(index, max(0, visibleCount - 1))
    }

    mutating func move(by delta: Int) {
        guard visibleCount > 0 else { index = 0; return }
        index = min(max(0, index + delta), visibleCount - 1)
    }

    mutating func clear() { matches = []; index = 0 }
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
