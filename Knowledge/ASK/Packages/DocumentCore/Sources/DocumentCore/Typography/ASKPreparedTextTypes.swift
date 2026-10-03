
public struct ASKPreparedTextKey: Sendable, Hashable, Codable {
    public let text: String
    public let font: ASKTypographyFontDescriptor
    public let options: ASKTypographyPreparationOptions

    public init(
        text: String,
        font: ASKTypographyFontDescriptor,
        options: ASKTypographyPreparationOptions = .init()
    ) {
        self.text = text
        self.font = font
        self.options = options
    }
}

public struct ASKPreparedTextStorageID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ASKPreparedTextHandle: Sendable, Hashable, Codable {
    public let storageID: ASKPreparedTextStorageID

    public init(storageID: ASKPreparedTextStorageID) {
        self.storageID = storageID
    }
}

public struct ASKTypographyRequest: Sendable, Hashable, Codable {
    public let key: ASKPreparedTextKey
    public let blockID: ASKPageBlockID
    public let style: ASKPageTextStyle

    public init(key: ASKPreparedTextKey, blockID: ASKPageBlockID, style: ASKPageTextStyle) {
        self.key = key
        self.blockID = blockID
        self.style = style
    }
}

public struct ASKTypographyRequestBuilder: Sendable {
    public init() {}

    public func makeRequest(
        for block: ASKPageBlock,
        font: ASKTypographyFontDescriptor,
        options: ASKTypographyPreparationOptions = .init()
    ) -> ASKTypographyRequest? {
        guard let textProjection = block.textProjection else {
            return nil
        }
        return ASKTypographyRequest(
            key: ASKPreparedTextKey(text: textProjection.text, font: font, options: options),
            blockID: block.id,
            style: textProjection.style
        )
    }

    public func extractRuns(from block: ASKPageBlock) -> [ASKPageInlineRun] {
        block.textProjection?.runs ?? []
    }
}
