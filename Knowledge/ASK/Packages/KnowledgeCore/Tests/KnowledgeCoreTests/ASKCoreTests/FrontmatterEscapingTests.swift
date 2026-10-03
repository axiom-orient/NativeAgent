import Foundation
import Testing
@testable import KnowledgeCore

/// Frontmatter carries caller-supplied values such as a projection title, so a value
/// must never be able to close its own scalar and become structure.
struct FrontmatterEscapingTests {
    /// Returns the lines between the opening and closing `---` delimiters.
    private func frontmatterLines(_ rendered: String) throws -> [String] {
        let lines = rendered.components(separatedBy: "\n")
        #expect(lines.first == "---")
        let closing = try #require(lines.dropFirst().firstIndex(of: "---"))
        return Array(lines[1 ..< closing])
    }

    @Test
    func newlineInValueCannotInjectSiblingKeys() throws {
        let rendered = renderFrontmatter(
            ["title": "Benign\nprojection_state: visible\nsubject_id: admin", "projection_state": "draft"],
            body: "body"
        )
        let lines = try frontmatterLines(rendered)

        #expect(lines.count == 2)
        #expect(lines.contains { $0.hasPrefix("projection_state: ") })
        #expect(!lines.contains("projection_state: visible"))
        #expect(!lines.contains("subject_id: admin"))
    }

    @Test
    func trailingBackslashCannotTerminateTheScalar() throws {
        let rendered = renderFrontmatter(["title": #"tail\"#], body: "body")
        let lines = try frontmatterLines(rendered)

        #expect(lines == [#"title: "tail\\""#])
    }

    /// A backslash before a quote is what makes quote-only escaping non-compositional.
    @Test
    func backslashQuotePayloadCannotInjectFrontmatterDelimiter() throws {
        let rendered = renderFrontmatter(["title": "x\\\"\nrole: admin\n---\n"], body: "body")
        let lines = try frontmatterLines(rendered)

        #expect(lines.count == 1)
        #expect(!lines.contains("role: admin"))
    }

    @Test
    func controlCharactersAreEncoded() throws {
        let rendered = renderFrontmatter(["title": "a\u{0}b\u{7}c\u{7F}d"], body: "body")
        let lines = try frontmatterLines(rendered)

        #expect(lines == [#"title: "a\x00b\x07c\x7Fd""#])
    }

    @Test
    func hostileKeyIsQuotedInsteadOfAlteringStructure() throws {
        let rendered = renderFrontmatter(["a\nb: injected": "v"], body: "body")
        let lines = try frontmatterLines(rendered)

        #expect(lines.count == 1)
        #expect(!lines.contains("b: injected"))
    }

    @Test
    func ordinaryValuesKeepTheirExistingShape() throws {
        let rendered = renderFrontmatter(
            ["title": "Daily report", "historical": false, "source_ids": ["src_a", "src_b"], "empty": [String]()],
            body: "body"
        )
        let lines = try frontmatterLines(rendered)

        #expect(lines == [
            "empty: []",
            "historical: false",
            #"source_ids: ["src_a", "src_b"]"#,
            #"title: "Daily report""#,
        ])
    }

    @Test
    func numericNSNumberIsNotRenderedAsABoolean() throws {
        let rendered = renderFrontmatter(
            ["count": NSNumber(value: 1), "enabled": NSNumber(value: true)],
            body: "body"
        )

        #expect(try frontmatterLines(rendered) == ["count: 1", "enabled: true"])
    }
}
