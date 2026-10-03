import XCTest
@testable import MarkdownSyntax

final class MarkdownSyntaxTests: XCTestCase, @unchecked Sendable {
    func testOutlineUsesCommonMarkHeadingRulesAndPreservesPreamble() {
        let markdown = """
        opening paragraph

        # ATX #
        body

        Setext title
        ============

        ~~~swift
        ## not a section
        ~~~

            # also code, not a section
        """

        let outline = MarkdownSyntaxParser.outline(markdown: markdown)

        XCTAssertEqual(outline.sections.map(\.title), ["ATX", "Setext title"])
        XCTAssertEqual(outline.sections.map(\.level), [1, 1])
        XCTAssertEqual(outline.sections.map(\.startLine), [3, 6])
        XCTAssertEqual(outline.preambleRange, MarkdownLineRange(startLine: 1, endLine: 2))
        XCTAssertFalse(outline.isHeaderless)
    }

    func testHeaderlessContentIsExplicitlyReported() {
        let outline = MarkdownSyntaxParser.outline(markdown: "plain text\nwith a second line\n")

        XCTAssertTrue(outline.sections.isEmpty)
        XCTAssertEqual(outline.preambleRange, MarkdownLineRange(startLine: 1, endLine: 3))
        XCTAssertTrue(outline.isHeaderless)
    }

    func testOutlineNormalizesCRLFAndLegacyCRBeforeUsingParserLocations() {
        let crlfOutline = MarkdownSyntaxParser.outline(markdown: "# Root\r\nbody\r\n\r\n## Child\r\ntext")
        XCTAssertEqual(crlfOutline.lineCount, 5)
        XCTAssertEqual(crlfOutline.sections.map(\.startLine), [1, 4])

        let legacyCROutline = MarkdownSyntaxParser.outline(markdown: "# Root\rbody\r## Child")
        XCTAssertEqual(legacyCROutline.lineCount, 3)
        XCTAssertEqual(legacyCROutline.sections.map(\.startLine), [1, 3])
    }
}
