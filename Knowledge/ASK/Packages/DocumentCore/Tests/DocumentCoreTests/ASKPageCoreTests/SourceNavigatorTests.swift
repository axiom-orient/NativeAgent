import Testing
@testable import DocumentCore

@Test("Source navigator finds inline runs overlapping a source span")
func sourceNavigatorFindsInlineRunsOverlappingSourceSpan() {
    let compiler = ASKPageMarkdownCompiler()
    let document = compiler.compile(
        markdown: "Hello [citation](ask-cite://paper-1)",
        documentID: .init("doc-1"),
        sourceID: .init("src-1")
    )
    let navigator = ASKPageSourceNavigator()

    let matches = navigator.inlineRuns(
        in: document.blocks[0],
        sourceID: .init("src-1"),
        overlapping: .init(start: 8, end: 14)
    )

    #expect(matches.count == 1)
    #expect(matches[0].run.text == "citation")
    #expect(matches[0].run.semanticRole == .citation(identifier: "paper-1"))
}

@Test("Source navigator can query code blocks through block-level source anchors")
func sourceNavigatorCanQueryCodeBlocksThroughBlockLevelAnchors() {
    let block = ASKPageBlock(
        id: .init("code-1"),
        kind: .code(.init(language: "swift", text: "let value = 1")),
        sourceAnchor: .init(sourceID: .init("src-1"), range: .init(start: 40, end: 53))
    )
    let navigator = ASKPageSourceNavigator()

    let matches = navigator.inlineRuns(
        in: block,
        sourceID: .init("src-1"),
        overlapping: .init(start: 44, end: 49)
    )

    #expect(matches.count == 1)
    #expect(matches[0].run.text == "let value = 1")
    #expect(matches[0].run.sourceAnchor?.range == .init(start: 40, end: 53))
}

@Test("Source navigator excludes inline runs without ranges from overlap queries")
func sourceNavigatorExcludesRangeLessAnchorsFromOverlapQueries() {
    let block = ASKPageBlock(
        id: .init("paragraph-1"),
        kind: .paragraph(.init(
            runs: [.init(text: "Loose", sourceAnchor: .init(sourceID: .init("src-1"), fragment: "#loose"))],
            style: .body
        )),
        sourceAnchor: .init(sourceID: .init("src-1"), fragment: "#loose")
    )
    let navigator = ASKPageSourceNavigator()

    let matches = navigator.inlineRuns(
        in: block,
        sourceID: .init("src-1"),
        overlapping: .init(start: 0, end: 1)
    )

    #expect(matches.isEmpty)
}


@Test("Source navigator can query list item runs after list projection synthesis")
func sourceNavigatorCanQueryListItemRuns() {
    let document = ASKPageMarkdownCompiler().compile(
        markdown: #"""
- Alpha
- [Beta](ask-entity://beta)
"""#,
        documentID: .init("doc-list"),
        sourceID: .init("src-list")
    )
    let navigator = ASKPageSourceNavigator()

    let matches = navigator.inlineRuns(
        in: document.blocks[0],
        sourceID: .init("src-list"),
        overlapping: .init(start: 10, end: 14)
    )

    #expect(matches.count == 1)
    #expect(matches[0].run.text == "Beta")
    #expect(matches[0].run.semanticRole == ASKPageInlineSemanticRole.entity(identifier: "beta"))
}
