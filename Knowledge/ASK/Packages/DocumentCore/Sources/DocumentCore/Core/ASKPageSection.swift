public struct ASKPageSection: Sendable, Hashable, Codable {
    public let id: ASKPageSectionID
    public let title: String
    public let level: Int
    public let sourceAnchor: ASKPageSourceAnchor?

    public init(
        id: ASKPageSectionID,
        title: String,
        level: Int,
        sourceAnchor: ASKPageSourceAnchor? = nil
    ) {
        self.id = id
        self.title = title
        self.level = level
        self.sourceAnchor = sourceAnchor
    }
}
