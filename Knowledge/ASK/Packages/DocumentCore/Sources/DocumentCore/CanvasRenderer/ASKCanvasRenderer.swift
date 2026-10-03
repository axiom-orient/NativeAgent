
public struct ASKCanvasRenderer: Sendable {
    private let typographyEngine: any ASKPreparedTypographyEngine

    public init(typographyEngine: any ASKPreparedTypographyEngine) {
        self.typographyEngine = typographyEngine
    }

    public func render(page: ASKCanvasPage, sourceID: ASKPageSourceID) async throws -> ASKRenderedCanvasPage {
        var renderedTextFragments: [ASKRenderedCanvasTextFragment] = []
        var renderedNotes: [ASKRenderedCanvasNote] = []

        for element in page.elements {
            switch element {
            case .obstacle:
                continue
            case let .note(note):
                renderedNotes.append(.init(text: note.text, frame: note.frame, sourceAnchor: note.anchor))
            case let .text(textElement):
                let rows = try await typographyEngine.layoutCanvasRows(textElement.request)
                let placements = ASKInlineLayoutPlacementBuilder.build(from: textElement.runs)
                for row in rows {
                    for fragment in row.fragments {
                        renderedTextFragments.append(contentsOf: makeRenderedFragments(
                            blockID: textElement.blockID,
                            laidOutLine: fragment,
                            lineHeight: textElement.request.metrics.lineHeight,
                            placements: placements,
                            fallbackSourceID: sourceID,
                            elementAnchor: textElement.sourceAnchor
                        ))
                    }
                }
            }
        }

        return .init(id: page.id, textFragments: renderedTextFragments, notes: renderedNotes)
    }

    private func makeRenderedFragments(
        blockID: ASKPageBlockID,
        laidOutLine: ASKLaidOutLine,
        lineHeight: Double,
        placements: [ASKInlineLayoutPlacement],
        fallbackSourceID: ASKPageSourceID,
        elementAnchor: ASKPageSourceAnchor?
    ) -> [ASKRenderedCanvasTextFragment] {
        let characterAdvance = laidOutLine.text.isEmpty ? 0 : laidOutLine.width / Double(laidOutLine.text.count)
        var currentX = laidOutLine.originX
        var fragments: [ASKRenderedCanvasTextFragment] = []

        for placement in placements {
            guard let overlap = placement.layoutRange.intersection(laidOutLine.sourceRange) else { continue }
            let text = placement.fragmentText(overlapping: overlap)
            guard !text.isEmpty else { continue }
            let width = Double(text.count) * characterAdvance
            let frame = ASKCanvasRect(x: currentX, y: laidOutLine.originY, width: width, height: lineHeight)
            fragments.append(.init(
                blockID: blockID,
                frame: frame,
                text: text,
                emphasis: placement.emphasis,
                destination: placement.destination,
                semanticRole: placement.semanticRole,
                sourceAnchor: makeSourceAnchor(
                    placement: placement,
                    overlap: overlap,
                    fallbackSourceID: fallbackSourceID,
                    elementAnchor: elementAnchor
                )
            ))
            currentX += width
        }

        if fragments.isEmpty {
            let frame = ASKCanvasRect(x: laidOutLine.originX, y: laidOutLine.originY, width: laidOutLine.width, height: lineHeight)
            fragments.append(.init(
                blockID: blockID,
                frame: frame,
                text: laidOutLine.text,
                emphasis: [],
                destination: nil,
                semanticRole: nil,
                sourceAnchor: makeSourceAnchor(
                    placement: nil,
                    overlap: laidOutLine.sourceRange,
                    fallbackSourceID: fallbackSourceID,
                    elementAnchor: elementAnchor
                )
            ))
        }

        return fragments
    }

    private func makeSourceAnchor(
        placement: ASKInlineLayoutPlacement?,
        overlap: ASKPageSourceRange,
        fallbackSourceID: ASKPageSourceID,
        elementAnchor: ASKPageSourceAnchor?
    ) -> ASKPageSourceAnchor {
        if let placementAnchor = placement?.projectedSourceAnchor(
            overlapping: overlap,
            fallbackFragment: elementAnchor?.fragment
        ) {
            return placementAnchor
        }
        if let elementAnchor, let anchorRange = elementAnchor.range {
            let fragmentRange = ASKPageSourceRange(
                start: anchorRange.start + overlap.start,
                end: anchorRange.start + overlap.end
            )
            return .init(sourceID: elementAnchor.sourceID, fragment: elementAnchor.fragment, range: fragmentRange)
        }
        if let elementAnchor {
            return .init(sourceID: elementAnchor.sourceID, fragment: elementAnchor.fragment, range: overlap)
        }
        return .init(sourceID: fallbackSourceID, range: overlap)
    }
}
