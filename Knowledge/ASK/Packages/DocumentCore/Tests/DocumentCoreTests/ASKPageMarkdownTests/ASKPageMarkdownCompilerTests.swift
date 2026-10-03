import Testing
@testable import DocumentCore

@Test("Markdown compiler assigns source ranges to inline runs")
func markdownCompilerAssignsInlineSourceRanges() {
    let markdown = "# Title\n\nHello **bold** [cite](ask-cite://paper-1) [entity](ask-entity://tensor) [link](https://example.com) \\*"
    let compiler = ASKPageMarkdownCompiler()

    let document = compiler.compile(
        markdown: markdown,
        documentID: .init("doc-1"),
        sourceID: .init("src-1")
    )

    #expect(document.title == "Title")
    #expect(document.sections.count == 1)
    #expect(document.blocks.count == 2)

    guard case let .paragraph(paragraph) = document.blocks[1].kind else {
        Issue.record("Expected paragraph block")
        return
    }

    let visibleRuns = paragraph.runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    #expect(visibleRuns.count == 6)
    #expect(visibleRuns[0].text == "Hello ")
    #expect(visibleRuns[0].sourceAnchor?.range == .init(start: 9, end: 15))
    #expect(visibleRuns[1].text == "bold")
    #expect(visibleRuns[1].sourceAnchor?.range == .init(start: 17, end: 21))
    #expect(visibleRuns[1].emphasis.contains(.bold))
    #expect(visibleRuns[2].semanticRole == .citation(identifier: "paper-1"))
    #expect(visibleRuns[2].sourceAnchor?.range == .init(start: 25, end: 29))
    #expect(visibleRuns[3].semanticRole == .entity(identifier: "tensor"))
    #expect(visibleRuns[3].sourceAnchor?.range == .init(start: 52, end: 58))
    #expect(visibleRuns[4].semanticRole == .link)
    #expect(visibleRuns[4].sourceAnchor?.range == .init(start: 82, end: 86))
    #expect(visibleRuns[5].text == "*")
    #expect(visibleRuns[5].sourceAnchor?.range == .init(start: 110, end: 111))
}
