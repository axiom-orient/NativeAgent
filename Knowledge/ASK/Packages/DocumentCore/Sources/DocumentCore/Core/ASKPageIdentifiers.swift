public protocol ASKPageID: RawRepresentable, Sendable, Hashable, Codable where RawValue == String {
    init(_ rawValue: String)
    init(rawValue: String)
}

public extension ASKPageID {
    init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }
}

public struct ASKPageDocumentID: ASKPageID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ASKPageSectionID: ASKPageID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ASKPageBlockID: ASKPageID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ASKPageCanvasSceneID: ASKPageID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ASKPageSourceID: ASKPageID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
