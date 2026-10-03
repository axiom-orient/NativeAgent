
public struct ASKRenderedSourceNavigator: Sendable {
    public init() {}

    public func fragments(
        in document: ASKRenderedDocument,
        sourceID: ASKPageSourceID,
        overlapping range: ASKPageSourceRange? = nil
    ) -> [ASKRenderedFragmentMatch] {
        document.blocks.flatMap { block in
            block.lines.enumerated().flatMap { lineIndex, line in
                line.fragments.enumerated().compactMap { fragmentIndex, fragment in
                    guard let anchor = fragment.sourceAnchor,
                          anchor.matches(sourceID: sourceID, overlapping: range)
                    else {
                        return nil
                    }
                    return ASKRenderedFragmentMatch(
                        blockID: block.blockID,
                        lineIndex: lineIndex,
                        fragmentIndex: fragmentIndex,
                        fragment: fragment
                    )
                }
            }
        }
    }
}

public struct ASKRenderedFragmentMatch: Sendable, Hashable, Codable {
    public let blockID: ASKPageBlockID
    public let lineIndex: Int
    public let fragmentIndex: Int
    public let fragment: ASKRenderedInlineFragment

    public init(blockID: ASKPageBlockID, lineIndex: Int, fragmentIndex: Int, fragment: ASKRenderedInlineFragment) {
        self.blockID = blockID
        self.lineIndex = lineIndex
        self.fragmentIndex = fragmentIndex
        self.fragment = fragment
    }
}
