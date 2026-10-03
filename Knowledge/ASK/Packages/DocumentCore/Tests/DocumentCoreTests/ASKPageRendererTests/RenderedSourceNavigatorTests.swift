import Testing
@testable import DocumentCore

@Test("Rendered source navigator finds fragments overlapping a source span")
func renderedSourceNavigatorFindsFragmentsOverlappingSourceSpan() async throws {
    let compiler = ASKPageMarkdownCompiler()
    let document = compiler.compile(
        markdown: "Hello [citation](ask-cite://paper-1) world",
        documentID: .init("doc-1"),
        sourceID: .init("src-1")
    )
    let renderer = ASKPageRenderer(typographyEngine: ASKPretextTypographyEngine())
    let rendered = try await renderer.render(
        document: document,
        configuration: .init(width: 120, font: .init(postScriptName: "System", pointSize: 10), metrics: .init(lineHeight: 14))
    )

    let matches = ASKRenderedSourceNavigator().fragments(
        in: rendered,
        sourceID: .init("src-1"),
        overlapping: .init(start: 8, end: 14)
    )

    #expect(matches.map { $0.fragment.text }.joined() == "citation")
    #expect(matches.allSatisfy { $0.fragment.semanticRole == .citation(identifier: "paper-1") })
}

@Test("Rendered source navigator excludes range-less fragments from overlap queries")
func renderedSourceNavigatorExcludesRangeLessFragmentsFromOverlapQueries() {
    let document = ASKRenderedDocument(blocks: [
        .init(
            blockID: .init("block-1"),
            style: .body,
            lines: [
                .init(
                    blockID: .init("block-1"),
                    originY: 0,
                    sourceRange: .init(start: 0, end: 5),
                    fragments: [
                        .init(
                            text: "Loose",
                            emphasis: [],
                            destination: nil,
                            semanticRole: nil,
                            sourceAnchor: .init(sourceID: .init("src-1"), fragment: "#loose")
                        )
                    ]
                )
            ]
        )
    ])

    let matches = ASKRenderedSourceNavigator().fragments(
        in: document,
        sourceID: .init("src-1"),
        overlapping: .init(start: 0, end: 1)
    )

    #expect(matches.isEmpty)
}
