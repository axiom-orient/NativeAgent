import Testing
@testable import DocumentCore

@Test("HTML export preserves source and semantic metadata on inline fragments")
func htmlExportPreservesSourceAndSemanticMetadata() async throws {
    let compiler = ASKPageMarkdownCompiler()
    let document = compiler.compile(
        markdown: "Hello [cite](ask-cite://paper-1) [tensor](ask-entity://tensor)",
        documentID: .init("doc-1"),
        sourceID: .init("src-1")
    )
    let renderer = ASKPageRenderer(typographyEngine: ASKPretextTypographyEngine())
    let rendered = try await renderer.render(
        document: document,
        configuration: .init(width: 200, font: .init(postScriptName: "System", pointSize: 10), metrics: .init(lineHeight: 14))
    )

    let html = ASKHTMLSnapshotExporter().export(document: rendered)
    #expect(html.contains("data-source-id=\"src-1\""))
    #expect(html.contains("data-semantic-role=\"citation\""))
    #expect(html.contains("data-semantic-id=\"paper-1\""))
    #expect(html.contains("data-semantic-role=\"entity\""))
    #expect(html.contains("data-semantic-id=\"tensor\""))
}

@Test("SVG export preserves source ranges on inline fragments")
func svgExportPreservesSourceRanges() async throws {
    let compiler = ASKPageMarkdownCompiler()
    let document = compiler.compile(
        markdown: "Alpha **Beta**",
        documentID: .init("doc-1"),
        sourceID: .init("src-1")
    )
    let renderer = ASKPageRenderer(typographyEngine: ASKPretextTypographyEngine())
    let rendered = try await renderer.render(
        document: document,
        configuration: .init(width: 80, font: .init(postScriptName: "System", pointSize: 10), metrics: .init(lineHeight: 14))
    )

    let svg = ASKSVGSnapshotExporter().export(document: rendered)
    #expect(svg.contains("data-source-id=\"src-1\""))
    #expect(svg.contains("data-source-start=\"8\""))
    #expect(svg.contains("data-source-end=\"12\""))
}

@Test("HTML export preserves synthesized code-block source ranges")
func htmlExportPreservesSynthesizedCodeBlockSourceRanges() async throws {
    let blockAnchor = ASKPageSourceAnchor(sourceID: .init("src-1"), range: .init(start: 30, end: 40))
    let document = ASKPageDocument(
        id: .init("doc-code"),
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

    let html = ASKHTMLSnapshotExporter().export(document: rendered)
    #expect(html.contains("data-source-id=\"src-1\""))
    #expect(html.contains("data-source-start=\"30\""))
    #expect(html.contains("data-source-end=\"34\""))
    #expect(html.contains("data-source-start=\"38\""))
    #expect(html.contains("data-source-end=\"40\""))
}

@Test("HTML export preserves list text and semantic metadata after synthesized projection")
func htmlExportPreservesListProjection() async throws {
    let document = ASKPageMarkdownCompiler().compile(
        markdown: #"""
- Alpha
- [Beta](ask-entity://beta)
"""#,
        documentID: .init("doc-list-export"),
        sourceID: .init("src-list-export")
    )
    let renderer = ASKPageRenderer(typographyEngine: ASKPretextTypographyEngine())
    let rendered = try await renderer.render(
        document: document,
        configuration: .init(width: 200, font: .init(postScriptName: "System", pointSize: 10), metrics: .init(lineHeight: 14))
    )

    let html = ASKHTMLSnapshotExporter().export(document: rendered)
    #expect(html.contains(">- <"))
    #expect(html.contains(">Beta<"))
    #expect(html.contains("data-semantic-role=\"entity\""))
    #expect(html.contains("data-semantic-id=\"beta\""))
    #expect(html.contains("data-source-id=\"src-list-export\""))
}
