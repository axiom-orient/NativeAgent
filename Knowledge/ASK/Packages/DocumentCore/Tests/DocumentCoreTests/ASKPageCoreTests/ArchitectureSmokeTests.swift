import Foundation
import Testing
@testable import DocumentCore

@Test("DocumentCore owns the pure page value surface")
func documentCoreOwnsPurePageSurface() {
    let document = ASKPageDocument(
        id: .init("doc-1"),
        title: "Title",
        source: .init(kind: .markdown),
        sections: [],
        blocks: []
    )

    #expect(document.id == .init("doc-1"))
}

@Test("Source anchors keep source identity and range hints")
func sourceAnchorStoresGroundingMetadata() {
    let anchor = ASKPageSourceAnchor(
        sourceID: .init("src-1"),
        fragment: "#intro",
        range: .init(start: 10, end: 32)
    )

    #expect(anchor.sourceID == .init("src-1"))
    #expect(anchor.fragment == "#intro")
    #expect(anchor.range?.start == 10)
    #expect(anchor.range?.end == 32)
}

@Test("Typography requests use named request rows and typed identifiers")
func typographyRequestsUseNamedRowsAndTypedIdentifiers() {
    let key = ASKPreparedTextKey(
        text: "Hello",
        font: .init(postScriptName: "SFProText-Regular", pointSize: 17, localeIdentifier: "ko-KR"),
        options: .init(whiteSpace: .preWrap, wordBreak: .keepAll, localeIdentifier: "ko-KR")
    )
    let request = ASKTypographyRequest(
        key: key,
        blockID: .init("block-1"),
        style: .body
    )
    let canvasRequest = ASKCanvasLayoutRequest(
        handle: .init(storageID: .init("prepared-1")),
        rows: [
            .init(fragments: [.init(originX: 0, maxWidth: 180)]),
            .init(fragments: [.init(originX: 24, maxWidth: 156)])
        ],
        metrics: .init(lineHeight: 24)
    )

    #expect(request.blockID == .init("block-1"))
    #expect(canvasRequest.handle.storageID == .init("prepared-1"))
    #expect(canvasRequest.rows.count == 2)
    #expect(canvasRequest.rows[1].fragments[0].originX == 24)
    #expect(key.options.whiteSpace == .preWrap)
    #expect(key.options.wordBreak == .keepAll)
}

@Test("Canvas obstacles use explicit geometry values")
func canvasObstaclesUseExplicitGeometryValues() {
    let obstacle = ASKCanvasObstacle(x: 10, y: 20, width: 120, height: 48)

    #expect(obstacle.frame.origin.x == 10)
    #expect(obstacle.frame.origin.y == 20)
    #expect(obstacle.frame.size.width == 120)
    #expect(obstacle.frame.size.height == 48)
    #expect(obstacle.width == 120)
}

@Test("Documents round-trip through Codable without losing typed structure")
func documentsRoundTripThroughCodable() throws {
    let document = ASKPageDocument(
        id: .init("doc-1"),
        title: "Title",
        source: .init(kind: .markdown, revision: "r1", authoritativeMarkdownPath: "doc.md"),
        sections: [
            .init(id: .init("s1"), title: "Intro", level: 1, sourceAnchor: .init(sourceID: .init("src-1"), fragment: "#intro"))
        ],
        blocks: [
            .init(
                id: .init("b1"),
                kind: .paragraph(.init(
                    runs: [
                        .init(text: "Hello", emphasis: [.bold, .citation], destination: URL(string: "https://example.com"))
                    ],
                    style: .body
                )),
                sectionID: .init("s1"),
                sourceAnchor: .init(sourceID: .init("src-1"), fragment: "#intro", range: .init(start: 1, end: 5))
            )
        ]
    )

    let encoded = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(ASKPageDocument.self, from: encoded)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let blocks = try #require(object["blocks"] as? [[String: Any]])
    let kind = try #require(blocks.first?["kind"] as? [String: Any])

    #expect(decoded == document)
    #expect(kind["type"] as? String == "paragraph")
    #expect(kind["value"] != nil)
    #expect(kind["_0"] == nil)
}
