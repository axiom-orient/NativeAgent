public import Foundation

public struct ASKPageInlineRun: Sendable, Hashable, Codable {
    public let text: String
    public let emphasis: ASKPageInlineEmphasis
    public let destination: URL?
    public let semanticRole: ASKPageInlineSemanticRole?
    public let sourceAnchor: ASKPageSourceAnchor?

    public init(
        text: String,
        emphasis: ASKPageInlineEmphasis = [],
        destination: URL? = nil,
        semanticRole: ASKPageInlineSemanticRole? = nil,
        sourceAnchor: ASKPageSourceAnchor? = nil
    ) {
        self.text = text
        self.emphasis = emphasis
        self.destination = destination
        self.semanticRole = semanticRole
        self.sourceAnchor = sourceAnchor
    }
}

public enum ASKPageInlineSemanticRole: Sendable, Hashable, Codable {
    case link
    case citation(identifier: String)
    case entity(identifier: String)
}

public struct ASKPageInlineEmphasis: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold = ASKPageInlineEmphasis(rawValue: 1 << 0)
    public static let italic = ASKPageInlineEmphasis(rawValue: 1 << 1)
    public static let code = ASKPageInlineEmphasis(rawValue: 1 << 2)
    public static let citation = ASKPageInlineEmphasis(rawValue: 1 << 3)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ASKPageTextStyle: String, Sendable, Hashable, Codable {
    case title
    case heading
    case body
    case quote
    case note
    case code
}
