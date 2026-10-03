public struct ASKPageSourceNavigator: Sendable {
    public init() {}

    public func blocks(
        in document: ASKPageDocument,
        sourceID: ASKPageSourceID,
        overlapping range: ASKPageSourceRange? = nil
    ) -> [ASKPageBlock] {
        document.blocks.filter { block in
            guard let anchor = block.sourceAnchor else {
                return false
            }
            return anchor.matches(sourceID: sourceID, overlapping: range)
        }
    }

    public func inlineRuns(
        in block: ASKPageBlock,
        sourceID: ASKPageSourceID,
        overlapping range: ASKPageSourceRange? = nil
    ) -> [ASKPageInlineRunMatch] {
        (block.textProjection?.runs ?? []).enumerated().compactMap { index, run in
            guard let anchor = run.sourceAnchor,
                  anchor.matches(sourceID: sourceID, overlapping: range)
            else {
                return nil
            }
            return ASKPageInlineRunMatch(blockID: block.id, runIndex: index, run: run)
        }
    }

}

public struct ASKPageInlineRunMatch: Sendable, Hashable, Codable {
    public let blockID: ASKPageBlockID
    public let runIndex: Int
    public let run: ASKPageInlineRun

    public init(blockID: ASKPageBlockID, runIndex: Int, run: ASKPageInlineRun) {
        self.blockID = blockID
        self.runIndex = runIndex
        self.run = run
    }
}
