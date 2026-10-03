public struct ASKPageDocument: Sendable, Hashable, Codable {
    public let id: ASKPageDocumentID
    public let title: String
    public let source: ASKPageSource
    public let sections: [ASKPageSection]
    public let blocks: [ASKPageBlock]

    public init(
        id: ASKPageDocumentID,
        title: String,
        source: ASKPageSource,
        sections: [ASKPageSection],
        blocks: [ASKPageBlock]
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.sections = sections
        self.blocks = blocks
    }
}
