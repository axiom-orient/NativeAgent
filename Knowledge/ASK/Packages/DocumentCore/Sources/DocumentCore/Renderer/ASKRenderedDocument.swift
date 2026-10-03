
public struct ASKRenderedDocument: Sendable, Hashable, Codable {
    public let blocks: [ASKRenderedBlock]

    public init(blocks: [ASKRenderedBlock]) {
        self.blocks = blocks
    }
}

public struct ASKRenderedBlock: Sendable, Hashable, Codable {
    public let blockID: ASKPageBlockID
    public let style: ASKPageTextStyle
    public let lines: [ASKRenderedLine]

    public init(blockID: ASKPageBlockID, style: ASKPageTextStyle, lines: [ASKRenderedLine]) {
        self.blockID = blockID
        self.style = style
        self.lines = lines
    }
}

public struct ASKRenderedLine: Sendable, Hashable, Codable {
    public let blockID: ASKPageBlockID
    public let originY: Double
    public let sourceRange: ASKPageSourceRange
    public let fragments: [ASKRenderedInlineFragment]

    public init(
        blockID: ASKPageBlockID,
        originY: Double,
        sourceRange: ASKPageSourceRange,
        fragments: [ASKRenderedInlineFragment]
    ) {
        self.blockID = blockID
        self.originY = originY
        self.sourceRange = sourceRange
        self.fragments = fragments
    }
}

public struct ASKRenderedInlineFragment: Sendable, Hashable, Codable {
    public let text: String
    public let emphasis: ASKPageInlineEmphasis
    public let destination: String?
    public let semanticRole: ASKPageInlineSemanticRole?
    public let sourceAnchor: ASKPageSourceAnchor?

    public init(
        text: String,
        emphasis: ASKPageInlineEmphasis,
        destination: String?,
        semanticRole: ASKPageInlineSemanticRole?,
        sourceAnchor: ASKPageSourceAnchor?
    ) {
        self.text = text
        self.emphasis = emphasis
        self.destination = destination
        self.semanticRole = semanticRole
        self.sourceAnchor = sourceAnchor
    }
}
