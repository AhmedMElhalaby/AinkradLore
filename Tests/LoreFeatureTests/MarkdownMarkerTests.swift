import XCTest
@testable import LoreFeature

/// Marker ranges must cover the SYNTAX CHARACTERS ONLY. A marker span that
/// swallows content will hide the content when Live Preview collapses it — a
/// user-visible disappearance of their text, which is why this task is
/// fixture-driven rather than spot-checked.
final class MarkdownMarkerTests: XCTestCase {

    private func markers(_ body: String) -> [(String, MarkerOwner)] {
        let model = MarkdownDocumentModel(body: body)
        let ns = body as NSString
        return model.styleSpans.compactMap { span in
            guard case .marker(let owner) = span.kind else { return nil }
            return (ns.substring(with: NSRange(location: span.range.lowerBound,
                                               length: span.range.count)), owner)
        }
    }

    func test_strongAndEmphasisMarkersCoverOnlyTheDelimiters() {
        let found = markers("a **bold** and *italic* here")
        XCTAssertEqual(found.filter { $0.1 == .strong }.map(\.0), ["**", "**"])
        XCTAssertEqual(found.filter { $0.1 == .emphasis }.map(\.0), ["*", "*"])
    }

    func test_underscoreSpellingsAreRecognised() {
        let found = markers("a __bold__ and _italic_ here")
        XCTAssertEqual(found.filter { $0.1 == .strong }.map(\.0), ["__", "__"])
        XCTAssertEqual(found.filter { $0.1 == .emphasis }.map(\.0), ["_", "_"])
    }

    func test_headingMarkerIncludesItsTrailingSpace() {
        // The space is part of the marker: leaving it visible when the hashes
        // are hidden indents the heading by one space, which reads as a bug.
        XCTAssertEqual(markers("### Title").filter { $0.1 == .heading }.map(\.0), ["### "])
    }

    /// A setext heading has no `#` to hide, so nothing is emitted rather than a
    /// guessed range over its first character.
    func test_setextHeadingEmitsNoMarker() {
        XCTAssertEqual(markers("Title\n=====").filter { $0.1 == .heading }.count, 0)
    }

    func test_wikilinkMarkersAreTheBracketsOnly() {
        XCTAssertEqual(markers("see [[Target]] now").filter { $0.1 == .wikilink }.map(\.0),
                       ["[[", "]]"])
    }

    func test_aliasedWikilinkClosesPastTheDisplayText() {
        XCTAssertEqual(markers("see [[Target|Shown]] now").filter { $0.1 == .wikilink }.map(\.0),
                       ["[[", "]]"])
    }

    func test_inlineCodeMarkersAreTheBackticks() {
        XCTAssertEqual(markers("a `code` b").filter { $0.1 == .inlineCode }.map(\.0),
                       ["`", "`"])
    }

    func test_inlineLinkMarkersHideTheDestination() {
        let found = markers("see [Design](Design.md) now").filter { $0.1 == .link }.map(\.0)
        XCTAssertEqual(found, ["[", "](Design.md)"])
    }

    func test_fenceMarkersCoverBothFenceLines() {
        let found = markers("```swift\nlet x = 1\n```").filter { $0.1 == .codeFence }
        XCTAssertEqual(found.count, 2, "opening and closing fences")
        XCTAssertTrue(found.allSatisfy { $0.0.contains("```") })
    }

    func test_unterminatedFenceEmitsOnlyTheOpener() {
        let found = markers("```swift\nlet x = 1\n").filter { $0.1 == .codeFence }
        XCTAssertEqual(found.map(\.0), ["```swift"])
    }

    func test_indentedCodeBlockEmitsNoFenceMarker() {
        XCTAssertEqual(markers("text\n\n    let x = 1\n").filter { $0.1 == .codeFence }.count, 0)
    }

    func test_blockQuoteAndBulletMarkers() {
        XCTAssertEqual(markers("> quoted").filter { $0.1 == .blockQuote }.map(\.0), ["> "])
        XCTAssertEqual(markers("- item").filter { $0.1 == .listBullet }.map(\.0), ["- "])
    }

    func test_orderedListBulletIncludesItsOrdinal() {
        XCTAssertEqual(markers("1. first").filter { $0.1 == .listBullet }.map(\.0), ["1. "])
    }

    /// CRLF has bitten this codebase repeatedly: "\r\n" is ONE Swift Character
    /// but TWO UTF-16 units, so any marker arithmetic done in Characters is
    /// wrong for a Windows-authored note.
    func test_markersAreCorrectInACRLFDocument() {
        XCTAssertEqual(markers("# A\r\n\r\n**b**").filter { $0.1 == .strong }.map(\.0),
                       ["**", "**"])
    }

    func test_wikilinkMarkersAreCorrectInACRLFDocument() {
        XCTAssertEqual(markers("# A\r\n\r\nsee [[T]]").filter { $0.1 == .wikilink }.map(\.0),
                       ["[[", "]]"])
    }

    /// Emoji are multi-unit in UTF-16; a marker offset computed in Characters
    /// lands mid-content after one.
    func test_markersAreCorrectAfterAnEmoji() {
        XCTAssertEqual(markers("🎉 **bold**").filter { $0.1 == .strong }.map(\.0),
                       ["**", "**"])
    }

    func test_wikilinkMarkersAreCorrectAfterAnEmoji() {
        XCTAssertEqual(markers("🎉 [[Target]]").filter { $0.1 == .wikilink }.map(\.0),
                       ["[[", "]]"])
    }

    /// A marker must never overlap another marker.
    func test_noMarkerOverlapsAContentSpanOfADifferentKind() {
        let model = MarkdownDocumentModel(body: "# H\n\n**b** `c` [[W]]\n\n> q\n\n- i")
        let markerRanges = model.styleSpans.compactMap { span -> Range<Int>? in
            if case .marker = span.kind { return span.range }
            return nil
        }
        for m in markerRanges {
            for other in markerRanges where other != m {
                XCTAssertTrue(m.upperBound <= other.lowerBound || other.upperBound <= m.lowerBound,
                              "markers must not overlap each other: \(m) vs \(other)")
            }
        }
    }

    /// A wikilink inside a fence is documentation about a link, not a link —
    /// and must not sprout bracket markers either.
    func test_wikilinkInsideAFenceHasNoMarkers() {
        XCTAssertEqual(markers("```\n[[Target]]\n```").filter { $0.1 == .wikilink }.count, 0)
    }

    /// Marker spans are ADDITIVE: every content span keeps the range it had.
    func test_contentSpansAreUnchangedByMarkerEmission() {
        let body = "## Head\n\n**b** *i* `c` [[W]]\n\n> q\n\n- [ ] task"
        let ns = body as NSString
        let content = MarkdownDocumentModel(body: body).styleSpans.filter {
            if case .marker = $0.kind { return false }
            return true
        }
        func text(_ kind: StyleSpan.Kind) -> [String] {
            content.filter { $0.kind == kind }.map {
                ns.substring(with: NSRange(location: $0.range.lowerBound,
                                           length: $0.range.count))
            }
        }
        XCTAssertEqual(text(.heading(2)), ["## Head"])
        XCTAssertEqual(text(.strong), ["**b**"])
        XCTAssertEqual(text(.emphasis), ["*i*"])
        XCTAssertEqual(text(.inlineCode), ["`c`"])
        XCTAssertEqual(text(.wikilink), ["W"])
        XCTAssertEqual(text(.checkbox(false)), ["[ ]"])
    }
}
