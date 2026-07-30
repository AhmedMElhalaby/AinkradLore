import XCTest
@testable import LoreFeature

final class MarkdownDocumentModelTests: XCTestCase {

    func test_reportsFencedCodeAsCode() {
        let text = "before\n\n```\nlet x = 1\n```\n\nafter\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        let inside = ns.range(of: "let x = 1").location
        XCTAssertTrue(model.isInsideCode(utf16Offset: inside))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "before").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "after").location))
    }

    func test_reportsInlineCodeAsCode() {
        let text = "a `code` b\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "code").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "b").location))
    }

    func test_skipsFrontmatterWhenComputingOffsets() {
        let text = "---\nid: a\ntitle: T\n---\n\n```\ncode\n```\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "code").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "title").location))
    }

    func test_handlesCRLFDocuments() {
        let text = "before\r\n\r\n```\r\ncode\r\n```\r\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "code").location))
    }

    func test_emptyDocumentDoesNotCrash() {
        let model = MarkdownDocumentModel(fullText: "")
        XCTAssertTrue(model.codeRangesUTF16.isEmpty)
        XCTAssertFalse(model.isInsideCode(utf16Offset: 0))
    }

    // MARK: - End-position convention

    /// Pins the inclusive-vs-exclusive question empirically.
    ///
    /// swift-markdown converts cmark's INCLUSIVE end column into an EXCLUSIVE
    /// one before handing over a `SourceRange`, so the reported range covers
    /// exactly "`code`" — backticks included, nothing beyond. If a `+1` were
    /// added when mapping, this substring would gain a trailing space; if
    /// cmark's raw inclusive column leaked through, it would lose the closing
    /// backtick.
    func test_inlineCodeRangeCoversExactlyTheSpanIncludingBackticks() {
        let text = "a `code` b\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(model.codeRangesUTF16.count, 1)
        let covered = (text as NSString).substring(with: model.codeRangesUTF16[0])
        XCTAssertEqual(covered, "`code`")
    }

    /// The character immediately after the closing backtick is NOT code.
    func test_codeRangeDoesNotOverrunByOne() {
        let text = "a `code` b\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        let closingTick = ns.range(of: "`code`").location + 5
        XCTAssertTrue(model.isInsideCode(utf16Offset: closingTick))
        XCTAssertFalse(model.isInsideCode(utf16Offset: closingTick + 1))
    }

    func test_reportsIndentedCodeAsCode() {
        let text = "para\n\n    indented code\n\ntail\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "indented").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "tail").location))
    }

    /// The reason this task exists: a wikilink inside a fence must be inside a
    /// reported code region so Task 4 can drop it.
    func test_wikilinkInsideFenceIsInsideCode() {
        let text = "real [[A]]\n\n```\n[[B]]\n```\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "[[A]]").location))
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "[[B]]").location))
    }

    /// Non-ASCII before the span: cmark columns are UTF-8 BYTES, so a naive
    /// column-as-offset mapping would land short.
    func test_handlesMultiByteCharactersBeforeInlineCode() {
        let text = "é👍 `code` x\n"
        let model = MarkdownDocumentModel(fullText: text)
        let covered = (text as NSString).substring(with: model.codeRangesUTF16[0])
        XCTAssertEqual(covered, "`code`")
    }

    // MARK: - Region kinds
    //
    // swift-markdown models fenced and indented code as the same `CodeBlock`
    // node, and `fenceInfo` is nil for a bare ``` opener as well as for
    // indented code, so the kind is derived from the source text at the
    // region's start. The link graph depends on this discrimination.

    func test_tagsFencedAndIndentedCodeBlocksDifferently() {
        let model = MarkdownDocumentModel(
            fullText: "```\nfenced\n```\n\npara\n\n    indented\n")
        XCTAssertEqual(model.codeRegions.map(\.kind),
                       [.fencedCodeBlock, .indentedCodeBlock])
    }

    /// Up to three leading spaces still make a fence.
    func test_tagsAnIndentedFenceAsFenced() {
        let model = MarkdownDocumentModel(fullText: "para\n\n   ```\n   x\n   ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    /// `CodeBlock.range` starts at the block's CONTENT, past any indent, so an
    /// indented block whose content is itself a fence looks fence-shaped from
    /// its start offset. The bare closing run inside its own content is what
    /// gives it away.
    func test_tagsAnIndentedBlockOfBackticksAsIndented() {
        let model = MarkdownDocumentModel(fullText: "para\n\n    ```\n    x\n    ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.indentedCodeBlock])
    }

    func test_tagsAnIndentedBlockOpeningWithAnInfoStringAsIndented() {
        let model = MarkdownDocumentModel(
            fullText: "para\n\n    ```swift\n    x\n    ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.indentedCodeBlock])
    }

    /// A fence pushed past column 4 by list nesting is still fenced.
    func test_tagsAListNestedFenceAsFenced() {
        let model = MarkdownDocumentModel(fullText: "- a\n  - b\n\n    ```\n    x\n    ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    func test_tagsABlockquotedFenceAsFenced() {
        let model = MarkdownDocumentModel(fullText: "> ```\n> x\n> ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    /// A shorter or non-bare run inside the content is not a closer.
    func test_tagsAFenceWithNonClosingRunsInItsContentAsFenced() {
        let model = MarkdownDocumentModel(fullText: "````\n```text\nx\n````\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    func test_tagsTildeFencesAsFenced() {
        let model = MarkdownDocumentModel(fullText: "~~~\nx\n~~~\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    func test_tagsInlineCodeAndHTMLBlocks() {
        let model = MarkdownDocumentModel(fullText: "a `c` b\n\n<div>\nx\n</div>\n")
        XCTAssertEqual(Set(model.codeRegions.map(\.kind)), [.inlineCode, .htmlBlock])
    }

    /// The kind-filtered query must ignore regions of other kinds, while the
    /// unfiltered one keeps its original all-kinds meaning.
    func test_kindFilteredQueryIgnoresOtherKinds() {
        let text = "para\n\n    indented\n"
        let model = MarkdownDocumentModel(fullText: text)
        let offset = (text as NSString).range(of: "indented").location
        XCTAssertTrue(model.isInsideCode(utf16Offset: offset))
        XCTAssertFalse(model.isInsideCode(utf16Offset: offset,
                                          kinds: MarkdownDocumentModel.linkSuppressingKinds))
    }
}
