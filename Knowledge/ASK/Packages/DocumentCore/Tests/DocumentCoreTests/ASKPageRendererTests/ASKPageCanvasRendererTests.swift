import Testing
@testable import DocumentCore

@Test("Canvas renderer preserves source anchors and semantic roles on text fragments")
func canvasRendererPreservesSourceAnchorsAndSemanticRoles() async throws {
    let runs: [ASKPageInlineRun] = [
        .init(text: "Canvas ", sourceAnchor: .init(sourceID: .init("src-1"), range: .init(start: 0, end: 7))),
        .init(text: "cite", semanticRole: .citation(identifier: "paper-1"), sourceAnchor: .init(sourceID: .init("src-1"), fragment: "scene.cite", range: .init(start: 7, end: 11))),
        .init(text: " tail", sourceAnchor: .init(sourceID: .init("src-1"), range: .init(start: 11, end: 16)))
    ]
    let request = ASKTypographyRequest(
        key: .init(text: runs.map(\.text).joined(), font: .init(postScriptName: "System", pointSize: 10)),
        blockID: .init("canvas-1"),
        style: .body
    )
    let engine = ASKPretextTypographyEngine()
    let handle = try await engine.prepare(request)
    let page = ASKCanvasPage(
        id: .init("scene-1"),
        elements: [
            .text(.init(
                blockID: .init("canvas-1"),
                runs: runs,
                request: .init(handle: handle, rows: [.init(fragments: [.init(originX: 0, maxWidth: 200)])], metrics: .init(lineHeight: 16)),
                sourceAnchor: .init(sourceID: .init("src-1"), fragment: "scene-1")
            )),
            .note(.init(
                text: "Canvas note",
                anchor: .init(sourceID: .init("src-1"), fragment: "scene.note", range: .init(start: 20, end: 31)),
                frame: .init(x: 0, y: 20, width: 120, height: 20)
            ))
        ]
    )

    let rendered = try await ASKCanvasRenderer(typographyEngine: engine).render(page: page, sourceID: .init("src-1"))
    let citation = rendered.textFragments.first { $0.semanticRole == .citation(identifier: "paper-1") }

    #expect(citation?.text == "cite")
    #expect(citation?.sourceAnchor?.sourceID == .init("src-1"))
    #expect(citation?.sourceAnchor?.fragment == "scene.cite")
    #expect(citation?.sourceAnchor?.range == .init(start: 7, end: 11))
    #expect(rendered.notes.first?.sourceAnchor?.fragment == "scene.note")
}

@Test("Canvas source navigator finds fragments and notes by source range")
func canvasSourceNavigatorFindsFragmentsAndNotesBySourceRange() async throws {
    let runs: [ASKPageInlineRun] = [
        .init(text: "Alpha", sourceAnchor: .init(sourceID: .init("src-1"), range: .init(start: 0, end: 5))),
        .init(text: "Beta", semanticRole: .entity(identifier: "tensor"), sourceAnchor: .init(sourceID: .init("src-1"), range: .init(start: 5, end: 9)))
    ]
    let request = ASKTypographyRequest(
        key: .init(text: runs.map(\.text).joined(), font: .init(postScriptName: "System", pointSize: 10)),
        blockID: .init("canvas-2"),
        style: .body
    )
    let engine = ASKPretextTypographyEngine()
    let handle = try await engine.prepare(request)
    let page = ASKCanvasPage(
        id: .init("scene-2"),
        elements: [
            .text(.init(blockID: .init("canvas-2"), runs: runs, request: .init(handle: handle, rows: [.init(fragments: [.init(originX: 0, maxWidth: 200)])], metrics: .init(lineHeight: 16)))),
            .note(.init(text: "Note", anchor: .init(sourceID: .init("src-1"), fragment: "scene.note", range: .init(start: 20, end: 24)), frame: .init(x: 10, y: 20, width: 80, height: 20)))
        ]
    )

    let rendered = try await ASKCanvasRenderer(typographyEngine: engine).render(page: page, sourceID: .init("src-1"))
    let navigator = ASKRenderedCanvasSourceNavigator()
    let fragmentMatches = navigator.fragments(in: rendered, sourceID: .init("src-1"), overlapping: .init(start: 4, end: 8))
    let noteMatches = navigator.notes(in: rendered, sourceID: .init("src-1"), overlapping: .init(start: 22, end: 23))

    #expect(fragmentMatches.count == 2)
    #expect(fragmentMatches.contains { $0.fragment.semanticRole == .entity(identifier: "tensor") })
    #expect(noteMatches.count == 1)
    #expect(noteMatches.first?.note.text == "Note")
}

@Test("Canvas renderer converts visible offsets back to original source offsets")
func canvasRendererConvertsVisibleOffsetsBackToOriginalSourceOffsets() async throws {
    let runs: [ASKPageInlineRun] = [
        .init(text: "Alpha ", sourceAnchor: .init(sourceID: .init("src-1"), range: .init(start: 0, end: 6))),
        .init(text: "cite", semanticRole: .citation(identifier: "paper-1"), sourceAnchor: .init(sourceID: .init("src-1"), fragment: "scene.cite", range: .init(start: 12, end: 16)))
    ]
    let request = ASKTypographyRequest(
        key: .init(text: runs.map(\.text).joined(), font: .init(postScriptName: "System", pointSize: 10)),
        blockID: .init("canvas-3"),
        style: .body
    )
    let engine = ASKPretextTypographyEngine()
    let handle = try await engine.prepare(request)
    let page = ASKCanvasPage(
        id: .init("scene-3"),
        elements: [
            .text(.init(blockID: .init("canvas-3"), runs: runs, request: .init(handle: handle, rows: [.init(fragments: [.init(originX: 0, maxWidth: 200)])], metrics: .init(lineHeight: 16))))
        ]
    )

    let rendered = try await ASKCanvasRenderer(typographyEngine: engine).render(page: page, sourceID: .init("src-1"))
    let citation = rendered.textFragments.first { $0.semanticRole == .citation(identifier: "paper-1") }

    #expect(citation?.text == "cite")
    #expect(citation?.sourceAnchor?.range == .init(start: 12, end: 16))
}

@Test("Canvas renderer maps element-level source ranges back onto unanchored runs")
func canvasRendererMapsElementLevelSourceRangesBackOntoUnanchoredRuns() async throws {
    let runs: [ASKPageInlineRun] = [
        .init(text: "Alpha"),
        .init(text: "Beta")
    ]
    let request = ASKTypographyRequest(
        key: .init(text: runs.map(\.text).joined(), font: .init(postScriptName: "System", pointSize: 10)),
        blockID: .init("canvas-absolute-range"),
        style: .body
    )
    let engine = ASKPretextTypographyEngine()
    let handle = try await engine.prepare(request)
    let page = ASKCanvasPage(
        id: .init("scene-absolute-range"),
        elements: [
            .text(.init(
                blockID: .init("canvas-absolute-range"),
                runs: runs,
                request: .init(handle: handle, rows: [.init(fragments: [.init(originX: 0, maxWidth: 200)])], metrics: .init(lineHeight: 16)),
                sourceAnchor: .init(sourceID: .init("src-1"), fragment: "scene.alpha-beta", range: .init(start: 100, end: 109))
            ))
        ]
    )

    let rendered = try await ASKCanvasRenderer(typographyEngine: engine).render(page: page, sourceID: .init("src-1"))

    #expect(rendered.textFragments.map(\.text) == ["Alpha", "Beta"])
    #expect(rendered.textFragments.compactMap { $0.sourceAnchor?.range } == [
        .init(start: 100, end: 105),
        .init(start: 105, end: 109)
    ])
}

@Test("Canvas source navigator excludes range-less notes from overlap queries")
func canvasSourceNavigatorExcludesRangeLessNotesFromOverlapQueries() {
    let page = ASKRenderedCanvasPage(
        id: .init("scene-4"),
        textFragments: [],
        notes: [
            .init(
                text: "Loose note",
                frame: .init(x: 0, y: 0, width: 10, height: 10),
                sourceAnchor: .init(sourceID: .init("src-1"), fragment: "scene.note")
            )
        ]
    )

    let matches = ASKRenderedCanvasSourceNavigator().notes(
        in: page,
        sourceID: .init("src-1"),
        overlapping: .init(start: 0, end: 1)
    )

    #expect(matches.isEmpty)
}

@Test("Typography engine rejects non-positive and non-finite point sizes")
func typographyEngineRejectsInvalidPointSizes() async throws {
    for value in [Double.nan, .infinity, -.infinity, 0, -1] {
        let request = ASKTypographyRequest(
            key: .init(text: "Invalid", font: .init(postScriptName: "System", pointSize: value)),
            blockID: .init("invalid-point-size"),
            style: .body
        )
        let engine = ASKPretextTypographyEngine()
        var matched = false
        do {
            _ = try await engine.prepare(request)
        } catch let error as ASKPretextTypographyError {
            if case let .invalidPointSize(actual) = error {
                matched = value.isNaN ? actual.isNaN : actual == value
            }
        }
        #expect(matched)
    }
}

@Test("Typography engine rejects invalid line heights in both layout paths")
func typographyEngineRejectsInvalidLineHeights() async throws {
    let engine = ASKPretextTypographyEngine()
    let handle = try await engine.prepare(.init(
        key: .init(text: "Invalid line height", font: .init(postScriptName: "System", pointSize: 10)),
        blockID: .init("invalid-line-height"),
        style: .body
    ))

    for value in [Double.nan, .infinity, -.infinity, 0, -1] {
        var lineFailure = false
        do {
            _ = try await engine.layoutLines(.init(handle: handle, width: 100, metrics: .init(lineHeight: value)))
        } catch let error as ASKPretextTypographyError {
            if case let .invalidLineHeight(actual) = error {
                lineFailure = value.isNaN ? actual.isNaN : actual == value
            }
        }
        #expect(lineFailure)

        var canvasFailure = false
        do {
            _ = try await engine.layoutCanvasRows(.init(
                handle: handle,
                rows: [.init(fragments: [.init(originX: 0, maxWidth: 100)])],
                metrics: .init(lineHeight: value)
            ))
        } catch let error as ASKPretextTypographyError {
            if case let .invalidLineHeight(actual) = error {
                canvasFailure = value.isNaN ? actual.isNaN : actual == value
            }
        }
        #expect(canvasFailure)
    }
}

@Test("Typography engine preserves unknown handles and finite geometry")
func typographyEnginePreservesHandleErrorsAndFiniteGeometry() async throws {
    let engine = ASKPretextTypographyEngine()
    let request = ASKTypographyRequest(
        key: .init(text: "Finite geometry", font: .init(postScriptName: "System", pointSize: 10)),
        blockID: .init("finite-geometry"),
        style: .body
    )
    let handle = try await engine.prepare(request)
    let lines = try await engine.layoutLines(.init(handle: handle, width: 100, metrics: .init(lineHeight: 16)))
    #expect(!lines.isEmpty)
    #expect(lines.allSatisfy { $0.width.isFinite && $0.originX.isFinite && $0.originY.isFinite })

    let rows = try await engine.layoutCanvasRows(.init(
        handle: handle,
        rows: [.init(fragments: [.init(originX: 0, maxWidth: 100)])],
        metrics: .init(lineHeight: 16)
    ))
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { row in
        row.originY.isFinite && row.visualWidth.isFinite && row.fragments.allSatisfy {
            $0.width.isFinite && $0.originX.isFinite && $0.originY.isFinite
        }
    })

    let unknown = ASKPreparedTextHandle(storageID: .init("missing"))
    var lineUnknown = false
    do {
        _ = try await engine.layoutLines(.init(handle: unknown, width: 100, metrics: .init(lineHeight: 16)))
    } catch ASKPretextTypographyError.unknownHandle {
        lineUnknown = true
    }
    #expect(lineUnknown)
}
