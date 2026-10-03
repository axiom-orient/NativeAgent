
public struct ASKPageRendererConfiguration: Sendable, Hashable, Codable {
    public let width: Double
    public let font: ASKTypographyFontDescriptor
    public let metrics: ASKTypographyLayoutMetrics

    public init(width: Double, font: ASKTypographyFontDescriptor, metrics: ASKTypographyLayoutMetrics) {
        self.width = width
        self.font = font
        self.metrics = metrics
    }
}

public struct ASKPageRenderer: Sendable {
    private let typographyEngine: any ASKPreparedTypographyEngine
    private let requestBuilder: ASKTypographyRequestBuilder

    public init(
        typographyEngine: any ASKPreparedTypographyEngine,
        requestBuilder: ASKTypographyRequestBuilder = .init()
    ) {
        self.typographyEngine = typographyEngine
        self.requestBuilder = requestBuilder
    }

    public func render(
        document: ASKPageDocument,
        configuration: ASKPageRendererConfiguration
    ) async throws -> ASKRenderedDocument {
        var renderedBlocks: [ASKRenderedBlock] = []

        for block in document.blocks {
            guard let request = requestBuilder.makeRequest(for: block, font: configuration.font) else {
                continue
            }
            let handle = try await typographyEngine.prepare(request)
            let lines = try await typographyEngine.layoutLines(
                .init(handle: handle, width: configuration.width, metrics: configuration.metrics)
            )
            let fragments = makeRenderedLines(block: block, laidOutLines: lines)
            renderedBlocks.append(.init(blockID: block.id, style: request.style, lines: fragments))
        }

        return ASKRenderedDocument(blocks: renderedBlocks)
    }

    private func makeRenderedLines(block: ASKPageBlock, laidOutLines: [ASKLaidOutLine]) -> [ASKRenderedLine] {
        let placements = ASKInlineLayoutPlacementBuilder.build(from: requestBuilder.extractRuns(from: block))

        return laidOutLines.map { line in
            let fragments = placements.compactMap { placement -> ASKRenderedInlineFragment? in
                guard let overlap = placement.layoutRange.intersection(line.sourceRange) else {
                    return nil
                }
                return ASKRenderedInlineFragment(
                    text: placement.fragmentText(overlapping: overlap),
                    emphasis: placement.emphasis,
                    destination: placement.destination,
                    semanticRole: placement.semanticRole,
                    sourceAnchor: placement.projectedSourceAnchor(overlapping: overlap)
                )
            }
            return ASKRenderedLine(
                blockID: block.id,
                originY: line.originY,
                sourceRange: line.sourceRange,
                fragments: fragments
            )
        }
    }
}
