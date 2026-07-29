import XCTest
@testable import LoreFeature

final class LinkParserTests: XCTestCase {
    private func targets(_ body: String) -> [String] {
        LinkParser.links(in: body).map(\.rawTarget)
    }

    func test_parsesPlainWikilink() {
        XCTAssertEqual(targets("see [[Design]] here"), ["Design"])
    }

    func test_parsesDisplayTextAndKeepsTargetClean() {
        let links = LinkParser.links(in: "see [[Design|the design]]")
        XCTAssertEqual(links.map(\.rawTarget), ["Design"])
        XCTAssertEqual(links.first?.displayText, "the design")
    }

    func test_keepsHeadingAndBlockFragmentsInTheTarget() {
        XCTAssertEqual(targets("[[Design#Overview]] and [[Design#^abc123]]"),
                       ["Design#Overview", "Design#^abc123"])
    }

    func test_flagsEmbeds() {
        let links = LinkParser.links(in: "![[Diagram]]")
        XCTAssertEqual(links.map(\.rawTarget), ["Diagram"])
        XCTAssertEqual(links.first?.isEmbed, true)
    }

    func test_parsesMarkdownLinksToLocalFiles() {
        XCTAssertEqual(targets("[text](notes/Design.md)"), ["notes/Design.md"])
    }

    func test_ignoresExternalMarkdownLinks() {
        XCTAssertEqual(targets("[site](https://example.com) [m](mailto:a@b.c)"), [])
    }

    func test_ignoresLinksInsideFencedCodeBlocks() {
        let body = """
        real [[One]]

        ```
        not a link [[Two]]
        ```

        real [[Three]]
        """
        XCTAssertEqual(targets(body), ["One", "Three"])
    }

    func test_ignoresLinksInsideTildeFencesAndInlineCode() {
        let body = """
        ~~~
        [[Fenced]]
        ~~~
        `[[Inline]]` but [[Real]]
        """
        XCTAssertEqual(targets(body), ["Real"])
    }

    func test_ignoresUnclosedLink() {
        XCTAssertEqual(targets("[[Unclosed and more text"), [])
    }

    func test_handlesUnicodeAndSpaces() {
        XCTAssertEqual(targets("[[Café Notes/Über Design]]"), ["Café Notes/Über Design"])
    }

    func test_emptyTargetIsIgnored() {
        XCTAssertEqual(targets("[[]] [[   ]]"), [])
    }

    // MARK: - Fence length / character matching (Finding 1)

    func test_longerFenceIsNotClosedByAShorterBareLineOfTheSameCharacter() {
        let body = """
        real [[Before]]

        ````
        ```
        not a link [[Inside]]
        ```
        ````

        real [[After]]
        """
        XCTAssertEqual(targets(body), ["Before", "After"])
    }

    func test_backtickFenceIsNotClosedByATildeFence() {
        let body = """
        ```
        [[Fenced]]
        ~~~
        still fenced [[AlsoFenced]]
        ```
        real [[Real]]
        """
        XCTAssertEqual(targets(body), ["Real"])
    }

    func test_tildeFenceIsNotClosedByABacktickFence() {
        let body = """
        ~~~
        [[Fenced]]
        ```
        still fenced [[AlsoFenced]]
        ~~~
        real [[Real]]
        """
        XCTAssertEqual(targets(body), ["Real"])
    }

    func test_fenceWithInfoStringOpensCorrectly() {
        let body = """
        ```swift
        let x = "[[NotALink]]"
        ```
        real [[Real]]
        """
        XCTAssertEqual(targets(body), ["Real"])
    }

    func test_unclosedFenceSwallowsRestOfDocument() {
        let body = """
        real [[Before]]

        ```
        [[Inside]]
        still no closer, [[AlsoInside]]
        """
        XCTAssertEqual(targets(body), ["Before"])
    }

    // MARK: - Dangling backtick (Finding 2)

    func test_danglingBacktickDoesNotSwallowRestOfLine() {
        XCTAssertEqual(targets("a ` stray backtick then [[Design]]"), ["Design"])
    }

    func test_balancedInlineCodeStillSkipsButLaterLinkIsFound() {
        XCTAssertEqual(targets("`code` then [[Design]]"), ["Design"])
    }

    func test_linkFullyInsideInlineCodeIsStillIgnored() {
        XCTAssertEqual(targets("`[[NotALink]]`"), [])
    }
}
