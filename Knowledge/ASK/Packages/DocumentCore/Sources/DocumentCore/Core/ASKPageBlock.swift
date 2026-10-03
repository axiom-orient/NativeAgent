public struct ASKPageBlock: Sendable, Hashable, Codable {
    public let id: ASKPageBlockID
    public let kind: ASKPageBlockKind
    public let sectionID: ASKPageSectionID?
    public let sourceAnchor: ASKPageSourceAnchor?

    public init(
        id: ASKPageBlockID,
        kind: ASKPageBlockKind,
        sectionID: ASKPageSectionID? = nil,
        sourceAnchor: ASKPageSourceAnchor? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sectionID = sectionID
        self.sourceAnchor = sourceAnchor
    }
}

public enum ASKPageBlockKind: Sendable, Hashable, Codable {
    case heading(ASKPageTextBlock)
    case paragraph(ASKPageTextBlock)
    case quote(ASKPageTextBlock)
    case code(ASKPageCodeBlock)
    case list(ASKPageListBlock)
    case note(ASKPageTextBlock)
    case canvas(ASKPageCanvasReference)
}

extension ASKPageBlockKind {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Discriminator: String, Codable {
        case heading
        case paragraph
        case quote
        case code
        case list
        case note
        case canvas
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Discriminator.self, forKey: .type) {
        case .heading:
            self = .heading(try container.decode(ASKPageTextBlock.self, forKey: .value))
        case .paragraph:
            self = .paragraph(try container.decode(ASKPageTextBlock.self, forKey: .value))
        case .quote:
            self = .quote(try container.decode(ASKPageTextBlock.self, forKey: .value))
        case .code:
            self = .code(try container.decode(ASKPageCodeBlock.self, forKey: .value))
        case .list:
            self = .list(try container.decode(ASKPageListBlock.self, forKey: .value))
        case .note:
            self = .note(try container.decode(ASKPageTextBlock.self, forKey: .value))
        case .canvas:
            self = .canvas(try container.decode(ASKPageCanvasReference.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heading(let value):
            try container.encode(Discriminator.heading, forKey: .type)
            try container.encode(value, forKey: .value)
        case .paragraph(let value):
            try container.encode(Discriminator.paragraph, forKey: .type)
            try container.encode(value, forKey: .value)
        case .quote(let value):
            try container.encode(Discriminator.quote, forKey: .type)
            try container.encode(value, forKey: .value)
        case .code(let value):
            try container.encode(Discriminator.code, forKey: .type)
            try container.encode(value, forKey: .value)
        case .list(let value):
            try container.encode(Discriminator.list, forKey: .type)
            try container.encode(value, forKey: .value)
        case .note(let value):
            try container.encode(Discriminator.note, forKey: .type)
            try container.encode(value, forKey: .value)
        case .canvas(let value):
            try container.encode(Discriminator.canvas, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct ASKPageTextBlock: Sendable, Hashable, Codable {
    public let runs: [ASKPageInlineRun]
    public let style: ASKPageTextStyle

    public init(runs: [ASKPageInlineRun], style: ASKPageTextStyle) {
        self.runs = runs
        self.style = style
    }
}

public struct ASKPageCodeBlock: Sendable, Hashable, Codable {
    public let language: String?
    public let text: String

    public init(language: String? = nil, text: String) {
        self.language = language
        self.text = text
    }
}

public struct ASKPageListBlock: Sendable, Hashable, Codable {
    public let ordered: Bool
    public let items: [[ASKPageInlineRun]]

    public init(ordered: Bool, items: [[ASKPageInlineRun]]) {
        self.ordered = ordered
        self.items = items
    }
}

public struct ASKPageCanvasReference: Sendable, Hashable, Codable {
    public let sceneID: ASKPageCanvasSceneID

    public init(sceneID: ASKPageCanvasSceneID) {
        self.sceneID = sceneID
    }
}
