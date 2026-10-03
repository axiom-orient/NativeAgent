import Testing
@testable import DocumentCore

@Test("Rendered inline fragments preserve source anchors and semantic roles")
func renderedInlineFragmentsPreserveSourceAnchorsAndSemanticRoles() async throws {
    let markdown = "Hello [citation](ask-cite://paper-1) and [entity](ask-entity://tensor) end"
    let compiler = ASKPageMarkdownCompiler()
    let document = compiler.compile(markdown: markdown, documentID: .init("doc-1"), sourceID: .init("src-1"))
    let renderer = ASKPageRenderer(typographyEngine: ASKPretextTypographyEngine())

    let rendered = try await renderer.render(
        document: document,
        configuration: .init(
            width: 120,
            font: .init(postScriptName: "System", pointSize: 10),
            metrics: .init(lineHeight: 14)
        )
    )

    let fragments = rendered.blocks.flatMap(\.lines).flatMap(\.fragments).filter { !$0.text.isEmpty }
    let citationFragments = fragments.filter { $0.semanticRole == .citation(identifier: "paper-1") }
    let entityFragments = fragments.filter { $0.semanticRole == .entity(identifier: "tensor") }

    #expect(!citationFragments.isEmpty)
    #expect(!entityFragments.isEmpty)
    #expect(citationFragments.allSatisfy { $0.sourceAnchor?.sourceID == .init("src-1") })
    #expect(entityFragments.allSatisfy { $0.sourceAnchor?.sourceID == .init("src-1") })
    #expect(citationFragments.map(\.text).joined() == "citation")
    #expect(entityFragments.map(\.text).joined() == "entity")
}

@Test("Rendered fragments split long inline runs without losing source offset continuity")
func renderedFragmentsSplitLongInlineRunsWithoutLosingSourceOffsetContinuity() async throws {
    let sourceAnchor = ASKPageSourceAnchor(sourceID: .init("src-1"), range: .init(start: 10, end: 20))
    let block = ASKPageBlock(
        id: .init("block-1"),
        kind: .paragraph(.init(
            runs: [.init(text: "ABCDEFGHIJ", emphasis: [.bold], sourceAnchor: sourceAnchor)],
            style: .body
        )),
        sourceAnchor: sourceAnchor
    )
    let document = ASKPageDocument(
        id: .init("doc-1"),
        title: "Test",
        source: .init(kind: .markdown),
        sections: [],
        blocks: [block]
    )
    let renderer = ASKPageRenderer(typographyEngine: ASKPretextTypographyEngine())

    let rendered = try await renderer.render(
        document: document,
        configuration: .init(
            width: 24,
            font: .init(postScriptName: "System", pointSize: 10),
            metrics: .init(lineHeight: 14)
        )
    )

    let fragments = rendered.blocks[0].lines.flatMap(\.fragments)
    #expect(fragments.map(\.text) == ["ABCD", "EFGH", "IJ"])
    #expect(fragments.compactMap { $0.sourceAnchor?.range } == [
        .init(start: 10, end: 14),
        .init(start: 14, end: 18),
        .init(start: 18, end: 20)
    ])
}

@Test("Rendered code fragments preserve block-level source anchors when runs are synthesized")
func renderedCodeFragmentsPreserveBlockLevelSourceAnchors() async throws {
    let blockAnchor = ASKPageSourceAnchor(sourceID: .init("src-1"), range: .init(start: 100, end: 110))
    let document = ASKPageDocument(
        id: .init("doc-1"),
        title: "Code",
        source: .init(kind: .markdown),
        sections: [],
        blocks: [
            .init(
                id: .init("code-1"),
                kind: .code(.init(language: "swift", text: "ABCDEFGHIJ")),
                sourceAnchor: blockAnchor
            )
        ]
    )
    let renderer = ASKPageRenderer(typographyEngine: ASKPretextTypographyEngine())

    let rendered = try await renderer.render(
        document: document,
        configuration: .init(width: 24, font: .init(postScriptName: "System", pointSize: 10), metrics: .init(lineHeight: 14))
    )

    let fragments = rendered.blocks[0].lines.flatMap(\.fragments)
    #expect(fragments.map(\.text) == ["ABCD", "EFGH", "IJ"])
    #expect(fragments.compactMap { $0.sourceAnchor?.range } == [
        .init(start: 100, end: 104),
        .init(start: 104, end: 108),
        .init(start: 108, end: 110)
    ])
}
