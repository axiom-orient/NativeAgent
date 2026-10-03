
public struct ASKLaidOutLine: Sendable, Hashable, Codable {
    public let text: String
    public let width: Double
    public let originX: Double
    public let originY: Double
    public let sourceRange: ASKPageSourceRange

    public init(
        text: String,
        width: Double,
        originX: Double,
        originY: Double,
        sourceRange: ASKPageSourceRange
    ) {
        self.text = text
        self.width = width
        self.originX = originX
        self.originY = originY
        self.sourceRange = sourceRange
    }
}

public struct ASKLaidOutRow: Sendable, Hashable, Codable {
    public let originY: Double
    public let fragments: [ASKLaidOutLine]
    public let visualWidth: Double

    public init(originY: Double, fragments: [ASKLaidOutLine], visualWidth: Double) {
        self.originY = originY
        self.fragments = fragments
        self.visualWidth = visualWidth
    }
}
