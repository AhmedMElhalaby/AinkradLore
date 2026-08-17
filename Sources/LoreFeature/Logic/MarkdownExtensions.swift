import Foundation

/// The four markdown syntaxes `swift-markdown` has no node for: `==highlight==`,
/// footnotes, `#tags` and `^block-ids`.
///
/// ## Why one scanner and not four
///
/// Highlight, strikethrough and math all use repeated ASCII punctuation and all
/// can nest. Four independent passes would make the precedence between them
/// EMERGENT — whichever happened to run first would win, and `==a $b== c$` would
/// have no defined answer. One ordered pass makes the precedence a stated
/// decision with a test per adjacent pair. See `order` below.
///
/// ## The rules it inherits
///
/// From `MarkdownMath`, whose shape this copies: the scanner may never CHANGE
/// THE TEXT. Every offset the index, the link graph and the MCP tools hold is
/// measured against the unmodified source.
///
/// From `MarkdownMarkers`: a malformed span emits NOTHING rather than a guess.
/// A missing span is cosmetic; a wrong one hides the user's own content once
/// Live Preview collapses it.
///
/// Every range is an absolute UTF-16 offset into the editor's full string,
/// frontmatter included — matching `StyleSpan.range`. Never `Character`
/// offsets, which misplace every span after an emoji.
public enum MarkdownExtensions {

    public struct Span: Equatable, Sendable {
        /// The whole source form, delimiters included.
        public let range: Range<Int>
        /// Between the delimiters. Equal to `range` for kinds that have none.
        public let content: Range<Int>
        public let kind: Kind
    }

    public enum Kind: Equatable, Sendable {
        case highlight
        case footnoteReference(label: String)
        case footnoteDefinition(label: String)
        case tag(name: String)
        case blockID(id: String)
    }

    /// Scans `text`, skipping every range in `masked`.
    ///
    /// `masked` carries the code regions AND the math expressions — computed by
    /// `MarkdownDocumentModel` and `MarkdownMath` respectively, and passed in
    /// rather than recomputed here so there is exactly one answer to "is this
    /// offset inside code" in the whole editor.
    ///
    /// - Parameter linkRanges: defaulted and unused until Task 5, which needs
    ///   it to keep a `#` inside a link target from becoming a tag.
    static func scan(_ text: NSString, masked: [Range<Int>],
                     linkRanges: [Range<Int>] = []) -> [Span] {
        var found: [Span] = []
        // Built ONCE per scan, not per character: `isClaimed` used to
        // construct a fresh `CodeRegionIndex` on every call, an O(n log n)
        // sort-and-coalesce paid once per offset scanned — O(n² log n)
        // overall, strictly worse than the linear scan it replaced. See
        // `MarkdownDocumentModel.swift:31-34`.
        let index = CodeRegionIndex(regions: masked.map {
            CodeRegion(range: NSRange(location: $0.lowerBound, length: $0.count),
                       kind: .fencedCodeBlock)
        }, kinds: nil)
        // Each scanner appends in the order listed. A later scanner never
        // claims an offset an earlier one already took — that is what makes
        // the precedence in `isClaimed` a decision rather than an accident.
        // Tasks 4-7 fill the rest in.
        scanHighlights(text, masked: index, found: &found)
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `==text==`. Paired, equal delimiters, SINGLE LINE — Obsidian's own
    /// behaviour, and the constraint that keeps a stray `==` from swallowing
    /// the rest of a document.
    private static func scanHighlights(_ text: NSString, masked: CodeRegionIndex,
                                       found: inout [Span]) {
        var i = 0
        while i + 1 < text.length {
            guard text.character(at: i) == 0x3D, text.character(at: i + 1) == 0x3D,
                  !isClaimed(i, masked: masked, found: found) else { i += 1; continue }
            let contentStart = i + 2
            var j = contentStart
            // Stop at the line end: an unclosed `==` must emit nothing, not
            // run on.
            while j + 1 < text.length, text.character(at: j) != 0x0A {
                if text.character(at: j) == 0x3D, text.character(at: j + 1) == 0x3D { break }
                j += 1
            }
            guard j + 1 < text.length,
                  text.character(at: j) == 0x3D, text.character(at: j + 1) == 0x3D,
                  j > contentStart,                                  // non-empty
                  !isClaimed(j, masked: masked, found: found) else { i += 1; continue }
            found.append(Span(range: i..<(j + 2), content: contentStart..<j, kind: .highlight))
            i = j + 2
        }
    }

    /// Whether `offset` is inside a masked region or an already-emitted span.
    ///
    /// `masked` is a pre-built `CodeRegionIndex`, constructed ONCE per `scan`
    /// call by the caller, not rebuilt here per character — see `scan`.
    /// `found` stays a linear scan: it holds only the spans emitted on this
    /// pass, so it is small, and indexing a list that grows during iteration
    /// would cost more than it saves.
    static func isClaimed(_ offset: Int, masked: CodeRegionIndex,
                          found: [Span]) -> Bool {
        masked.contains(offset) || found.contains { $0.range.contains(offset) }
    }
}
