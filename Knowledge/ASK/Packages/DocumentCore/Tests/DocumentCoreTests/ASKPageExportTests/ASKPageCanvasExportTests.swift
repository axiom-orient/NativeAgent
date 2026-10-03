import Testing
@testable import DocumentCore

@Test("Canvas HTML export preserves source and semantic metadata")
func canvasHTMLExportPreservesSourceAndSemanticMetadata() async throws {
    let runs: [ASKPageInlineRun] = [
        .init(text: "Canvas ", sourceAnchor: .init(sourceID: .init("src-1"), range: .init(start: 0, end: 7))),
        .init(text: "cite", semanticRole: .citation(identifier: "paper-1"), sourceAnchor: .init(sourceID: .init("src-1"), fragment: "scene.cite", range: .init(start: 7, end: 11)))
    ]
    let request = ASKTypographyRequest(
        key: .init(text: runs.map(\.text).joined(), font: .init(postScriptName: "System", pointSize: 10)),
        blockID: .init("canvas-export"),
        style: .body
    )
    let engine = ASKPretextTypographyEngine()
    let handle = try await engine.prepare(request)
    let canvas = ASKCanvasPage(
        id: .init("scene-export"),
        elements: [
            .text(.init(blockID: .init("canvas-export"), runs: runs, request: .init(handle: handle, rows: [.init(fragments: [.init(originX: 0, maxWidth: 200)])], metrics: .init(lineHeight: 16)))),
            .note(.init(text: "Note", anchor: .init(sourceID: .init("src-1"), fragment: "scene.note", range: .init(start: 20, end: 24)), frame: .init(x: 0, y: 18, width: 90, height: 20)))
        ]
    )
    let rendered = try await ASKCanvasRenderer(typographyEngine: engine).render(page: canvas, sourceID: .init("src-1"))

    let html = ASKHTMLSnapshotExporter().export(canvasPage: rendered)
    #expect(html.contains("data-canvas-id=\"scene-export\""))
    #expect(html.contains("data-source-id=\"src-1\""))
    #expect(html.contains("data-semantic-role=\"citation\""))
    #expect(html.contains("data-semantic-id=\"paper-1\""))
    #expect(html.contains("data-source-fragment=\"scene.note\""))
}

@Test("Canvas SVG export preserves source ranges")
func canvasSVGExportPreservesSourceRanges() async throws {
    let runs: [ASKPageInlineRun] = [
        .init(text: "Alpha", sourceAnchor: .init(sourceID: .init("src-1"), range: .init(start: 0, end: 5))),
        .init(text: "Beta", sourceAnchor: .init(sourceID: .init("src-1"), range: .init(start: 5, end: 9)))
    ]
    let request = ASKTypographyRequest(
        key: .init(text: runs.map(\.text).joined(), font: .init(postScriptName: "System", pointSize: 10)),
        blockID: .init("canvas-export-2"),
        style: .body
    )
    let engine = ASKPretextTypographyEngine()
    let handle = try await engine.prepare(request)
    let canvas = ASKCanvasPage(
        id: .init("scene-export-2"),
        elements: [
            .text(.init(blockID: .init("canvas-export-2"), runs: runs, request: .init(handle: handle, rows: [.init(fragments: [.init(originX: 0, maxWidth: 200)])], metrics: .init(lineHeight: 16))))
        ]
    )
    let rendered = try await ASKCanvasRenderer(typographyEngine: engine).render(page: canvas, sourceID: .init("src-1"))

    let svg = ASKSVGSnapshotExporter().export(canvasPage: rendered)
    #expect(svg.contains("data-source-id=\"src-1\""))
    #expect(svg.contains("data-source-start=\"0\""))
    #expect(svg.contains("data-source-end=\"5\""))
}
