import Testing
@testable import DocumentCore

@Test("Page renderer renders list blocks through synthesized text projection")
func pageRendererRendersListBlocksThroughTextProjection() async throws {
    let document = ASKPageMarkdownCompiler().compile(
        markdown: "- Alpha\n- [Beta](ask-entity://beta)\n\n1. One\n2. Two",
        documentID: .init("doc-list-render"),
        sourceID: .init("src-list-render")
    )
    let renderer = ASKPageRenderer(typographyEngine: ASKPretextTypographyEngine())

    let rendered = try await renderer.render(
        document: document,
        configuration: .init(width: 200, font: .init(postScriptName: "System", pointSize: 10), metrics: .init(lineHeight: 14))
    )

    #expect(rendered.blocks.count == 2)

    let unorderedLines = rendered.blocks[0].lines.map { $0.fragments.map(\.text).joined() }
    let orderedLines = rendered.blocks[1].lines.map { $0.fragments.map(\.text).joined() }
    #expect(unorderedLines == ["- Alpha", "- Beta"])
    #expect(orderedLines == ["1. One", "2. Two"])

    let entityFragment = rendered.blocks[0].lines.flatMap(\.fragments).first {
        $0.semanticRole == .entity(identifier: "beta")
    }
    #expect(entityFragment?.text == "Beta")
    #expect(entityFragment?.sourceAnchor?.sourceID == .init("src-list-render"))
}
