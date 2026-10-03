
public enum ASKCanvasElement: Sendable, Hashable, Codable {
    case text(ASKCanvasTextElement)
    case note(ASKCanvasNoteElement)
    case obstacle(ASKCanvasObstacle)
}

public struct ASKCanvasTextElement: Sendable, Hashable, Codable {
    public let blockID: ASKPageBlockID
    public let runs: [ASKPageInlineRun]
    public let request: ASKCanvasLayoutRequest
    public let sourceAnchor: ASKPageSourceAnchor?

    public init(
        blockID: ASKPageBlockID,
        runs: [ASKPageInlineRun],
        request: ASKCanvasLayoutRequest,
        sourceAnchor: ASKPageSourceAnchor? = nil
    ) {
        self.blockID = blockID
        self.runs = runs
        self.request = request
        self.sourceAnchor = sourceAnchor
    }
}

public struct ASKCanvasNoteElement: Sendable, Hashable, Codable {
    public let text: String
    public let anchor: ASKPageSourceAnchor?
    public let frame: ASKCanvasRect

    public init(text: String, anchor: ASKPageSourceAnchor? = nil, frame: ASKCanvasRect) {
        self.text = text
        self.anchor = anchor
        self.frame = frame
    }
}
