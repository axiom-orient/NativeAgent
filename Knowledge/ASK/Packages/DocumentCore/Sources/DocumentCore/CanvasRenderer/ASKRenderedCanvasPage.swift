
public struct ASKRenderedCanvasTextFragment: Sendable, Hashable, Codable {
    public let blockID: ASKPageBlockID
    public let frame: ASKCanvasRect
    public let text: String
    public let emphasis: ASKPageInlineEmphasis
    public let destination: String?
    public let semanticRole: ASKPageInlineSemanticRole?
    public let sourceAnchor: ASKPageSourceAnchor?

    public init(
        blockID: ASKPageBlockID,
        frame: ASKCanvasRect,
        text: String,
        emphasis: ASKPageInlineEmphasis,
        destination: String?,
        semanticRole: ASKPageInlineSemanticRole?,
        sourceAnchor: ASKPageSourceAnchor?
    ) {
        self.blockID = blockID
        self.frame = frame
        self.text = text
        self.emphasis = emphasis
        self.destination = destination
        self.semanticRole = semanticRole
        self.sourceAnchor = sourceAnchor
    }
}

public struct ASKRenderedCanvasNote: Sendable, Hashable, Codable {
    public let text: String
    public let frame: ASKCanvasRect
    public let sourceAnchor: ASKPageSourceAnchor?

    public init(text: String, frame: ASKCanvasRect, sourceAnchor: ASKPageSourceAnchor?) {
        self.text = text
        self.frame = frame
        self.sourceAnchor = sourceAnchor
    }
}

public struct ASKRenderedCanvasPage: Sendable, Hashable, Codable {
    public let id: ASKPageCanvasSceneID
    public let textFragments: [ASKRenderedCanvasTextFragment]
    public let notes: [ASKRenderedCanvasNote]

    public init(id: ASKPageCanvasSceneID, textFragments: [ASKRenderedCanvasTextFragment], notes: [ASKRenderedCanvasNote]) {
        self.id = id
        self.textFragments = textFragments
        self.notes = notes
    }
}
