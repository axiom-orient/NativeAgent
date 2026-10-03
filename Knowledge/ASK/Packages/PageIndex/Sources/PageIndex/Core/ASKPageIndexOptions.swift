import Foundation

public enum ToggleFlag: String, Codable, CaseIterable, Sendable {
    case yes
    case no

    public var boolValue: Bool { self == .yes }

    public init?(parsing value: String?) {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes": self = .yes
        case "no": self = .no
        default: return nil
        }
    }

    public init(_ value: Bool) {
        self = value ? .yes : .no
    }
}

public enum DocumentType: String, Codable, CaseIterable, Sendable {
    case pdf
    case md
}

public enum DocumentInputMode: String, CaseIterable, Sendable {
    case auto
    case pdf
    case md

    public init?(parsing value: String?) {
        guard let value else { return nil }
        self.init(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

public struct ASKPageIndexOptionOverrides: Sendable, Equatable {
    public var model: String?
    public var retrieveModel: String?
    public var tocCheckPageNum: Int?
    public var maxPageNumEachNode: Int?
    public var maxTokenNumEachNode: Int?
    public var ifAddNodeID: ToggleFlag?
    public var ifAddNodeSummary: ToggleFlag?
    public var ifAddDocDescription: ToggleFlag?
    public var ifAddNodeText: ToggleFlag?
    public var ifThinning: Bool?
    public var minTokenThreshold: Int?
    public var summaryTokenThreshold: Int?

    public init(
        model: String? = nil,
        retrieveModel: String? = nil,
        tocCheckPageNum: Int? = nil,
        maxPageNumEachNode: Int? = nil,
        maxTokenNumEachNode: Int? = nil,
        ifAddNodeID: ToggleFlag? = nil,
        ifAddNodeSummary: ToggleFlag? = nil,
        ifAddDocDescription: ToggleFlag? = nil,
        ifAddNodeText: ToggleFlag? = nil,
        ifThinning: Bool? = nil,
        minTokenThreshold: Int? = nil,
        summaryTokenThreshold: Int? = nil
    ) {
        self.model = model
        self.retrieveModel = retrieveModel
        self.tocCheckPageNum = tocCheckPageNum
        self.maxPageNumEachNode = maxPageNumEachNode
        self.maxTokenNumEachNode = maxTokenNumEachNode
        self.ifAddNodeID = ifAddNodeID
        self.ifAddNodeSummary = ifAddNodeSummary
        self.ifAddDocDescription = ifAddDocDescription
        self.ifAddNodeText = ifAddNodeText
        self.ifThinning = ifThinning
        self.minTokenThreshold = minTokenThreshold
        self.summaryTokenThreshold = summaryTokenThreshold
    }

    public var isEmpty: Bool {
        model == nil &&
        retrieveModel == nil &&
        tocCheckPageNum == nil &&
        maxPageNumEachNode == nil &&
        maxTokenNumEachNode == nil &&
        ifAddNodeID == nil &&
        ifAddNodeSummary == nil &&
        ifAddDocDescription == nil &&
        ifAddNodeText == nil &&
        ifThinning == nil &&
        minTokenThreshold == nil &&
        summaryTokenThreshold == nil
    }
}

public struct ASKPageIndexOptions: Codable, Sendable, Equatable {
    public var model: String?
    public var retrieveModel: String?
    public var tocCheckPageNum: Int
    public var maxPageNumEachNode: Int
    public var maxTokenNumEachNode: Int
    public var ifAddNodeID: ToggleFlag
    public var ifAddNodeSummary: ToggleFlag
    public var ifAddDocDescription: ToggleFlag
    public var ifAddNodeText: ToggleFlag
    public var ifThinning: Bool
    public var minTokenThreshold: Int?
    public var summaryTokenThreshold: Int

    public init(
        model: String? = nil,
        retrieveModel: String? = nil,
        tocCheckPageNum: Int,
        maxPageNumEachNode: Int,
        maxTokenNumEachNode: Int,
        ifAddNodeID: ToggleFlag,
        ifAddNodeSummary: ToggleFlag,
        ifAddDocDescription: ToggleFlag,
        ifAddNodeText: ToggleFlag,
        ifThinning: Bool = false,
        minTokenThreshold: Int? = nil,
        summaryTokenThreshold: Int = 200
    ) {
        self.model = model
        self.retrieveModel = retrieveModel
        self.tocCheckPageNum = tocCheckPageNum
        self.maxPageNumEachNode = maxPageNumEachNode
        self.maxTokenNumEachNode = maxTokenNumEachNode
        self.ifAddNodeID = ifAddNodeID
        self.ifAddNodeSummary = ifAddNodeSummary
        self.ifAddDocDescription = ifAddDocDescription
        self.ifAddNodeText = ifAddNodeText
        self.ifThinning = ifThinning
        self.minTokenThreshold = minTokenThreshold
        self.summaryTokenThreshold = summaryTokenThreshold
    }

    public func merged(with overrides: ASKPageIndexOptionOverrides) -> ASKPageIndexOptions {
        ASKPageIndexOptions(
            model: overrides.model ?? model,
            retrieveModel: overrides.retrieveModel ?? retrieveModel,
            tocCheckPageNum: overrides.tocCheckPageNum ?? tocCheckPageNum,
            maxPageNumEachNode: overrides.maxPageNumEachNode ?? maxPageNumEachNode,
            maxTokenNumEachNode: overrides.maxTokenNumEachNode ?? maxTokenNumEachNode,
            ifAddNodeID: overrides.ifAddNodeID ?? ifAddNodeID,
            ifAddNodeSummary: overrides.ifAddNodeSummary ?? ifAddNodeSummary,
            ifAddDocDescription: overrides.ifAddDocDescription ?? ifAddDocDescription,
            ifAddNodeText: overrides.ifAddNodeText ?? ifAddNodeText,
            ifThinning: overrides.ifThinning ?? ifThinning,
            minTokenThreshold: overrides.minTokenThreshold ?? minTokenThreshold,
            summaryTokenThreshold: overrides.summaryTokenThreshold ?? summaryTokenThreshold
        )
    }

    enum CodingKeys: String, CodingKey {
        case model
        case retrieveModel = "retrieve_model"
        case tocCheckPageNum = "toc_check_page_num"
        case maxPageNumEachNode = "max_page_num_each_node"
        case maxTokenNumEachNode = "max_token_num_each_node"
        case ifAddNodeID = "if_add_node_id"
        case ifAddNodeSummary = "if_add_node_summary"
        case ifAddDocDescription = "if_add_doc_description"
        case ifAddNodeText = "if_add_node_text"
        case ifThinning = "if_thinning"
        case minTokenThreshold = "min_token_threshold"
        case summaryTokenThreshold = "summary_token_threshold"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            model: try container.decodeIfPresent(String.self, forKey: .model),
            retrieveModel: try container.decodeIfPresent(String.self, forKey: .retrieveModel),
            tocCheckPageNum: try container.decode(Int.self, forKey: .tocCheckPageNum),
            maxPageNumEachNode: try container.decode(Int.self, forKey: .maxPageNumEachNode),
            maxTokenNumEachNode: try container.decode(Int.self, forKey: .maxTokenNumEachNode),
            ifAddNodeID: try container.decode(ToggleFlag.self, forKey: .ifAddNodeID),
            ifAddNodeSummary: try container.decode(ToggleFlag.self, forKey: .ifAddNodeSummary),
            ifAddDocDescription: try container.decode(ToggleFlag.self, forKey: .ifAddDocDescription),
            ifAddNodeText: try container.decode(ToggleFlag.self, forKey: .ifAddNodeText),
            ifThinning: try container.decodeIfPresent(Bool.self, forKey: .ifThinning) ?? false,
            minTokenThreshold: try container.decodeIfPresent(Int.self, forKey: .minTokenThreshold),
            summaryTokenThreshold: try container.decodeIfPresent(Int.self, forKey: .summaryTokenThreshold) ?? 200
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(retrieveModel, forKey: .retrieveModel)
        try container.encode(tocCheckPageNum, forKey: .tocCheckPageNum)
        try container.encode(maxPageNumEachNode, forKey: .maxPageNumEachNode)
        try container.encode(maxTokenNumEachNode, forKey: .maxTokenNumEachNode)
        try container.encode(ifAddNodeID, forKey: .ifAddNodeID)
        try container.encode(ifAddNodeSummary, forKey: .ifAddNodeSummary)
        try container.encode(ifAddDocDescription, forKey: .ifAddDocDescription)
        try container.encode(ifAddNodeText, forKey: .ifAddNodeText)
        try container.encode(ifThinning, forKey: .ifThinning)
        try container.encodeIfPresent(minTokenThreshold, forKey: .minTokenThreshold)
        try container.encode(summaryTokenThreshold, forKey: .summaryTokenThreshold)
    }
}
