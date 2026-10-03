import Foundation

public struct ConfigLoader: Sendable {
    private let defaultOptions: ASKPageIndexOptions

    public init(yamlText: String? = nil) throws {
        let source = try yamlText ?? Self.loadBundledYAML()
        self.defaultOptions = try Self.parse(yamlText: source)
    }

    public func load(overrides: ASKPageIndexOptionOverrides = .init()) -> ASKPageIndexOptions {
        defaultOptions.merged(with: overrides)
    }

    private static func loadBundledYAML() throws -> String {
        guard let url = Bundle.module.url(forResource: "config", withExtension: "yaml") else {
            throw ASKPageIndexError.decodeFailure("Bundled config.yaml not found")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func parse(yamlText: String) throws -> ASKPageIndexOptions {
        var values: [String: String] = [:]
        for rawLine in yamlText.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }

        let allowedKeys: Set<String> = [
            "model",
            "retrieve_model",
            "toc_check_page_num",
            "max_page_num_each_node",
            "max_token_num_each_node",
            "if_add_node_id",
            "if_add_node_summary",
            "if_add_doc_description",
            "if_add_node_text",
            "if_thinning",
            "min_token_threshold",
            "summary_token_threshold",
        ]
        let unknownKeys = Set(values.keys).subtracting(allowedKeys)
        if !unknownKeys.isEmpty {
            throw ASKPageIndexError.unknownConfigKeys(unknownKeys)
        }

        guard
            let tocCheckPageNum = Int(values["toc_check_page_num"] ?? ""),
            let maxPageNumEachNode = Int(values["max_page_num_each_node"] ?? ""),
            let maxTokenNumEachNode = Int(values["max_token_num_each_node"] ?? ""),
            let ifAddNodeID = ToggleFlag(parsing: values["if_add_node_id"]),
            let ifAddNodeSummary = ToggleFlag(parsing: values["if_add_node_summary"]),
            let ifAddDocDescription = ToggleFlag(parsing: values["if_add_doc_description"]),
            let ifAddNodeText = ToggleFlag(parsing: values["if_add_node_text"])
        else {
            throw ASKPageIndexError.decodeFailure("config.yaml is missing one or more required values")
        }

        return ASKPageIndexOptions(
            model: values["model"],
            retrieveModel: values["retrieve_model"],
            tocCheckPageNum: tocCheckPageNum,
            maxPageNumEachNode: maxPageNumEachNode,
            maxTokenNumEachNode: maxTokenNumEachNode,
            ifAddNodeID: ifAddNodeID,
            ifAddNodeSummary: ifAddNodeSummary,
            ifAddDocDescription: ifAddDocDescription,
            ifAddNodeText: ifAddNodeText,
            ifThinning: boolValue(values["if_thinning"]) ?? false,
            minTokenThreshold: values["min_token_threshold"].flatMap(Int.init),
            summaryTokenThreshold: values["summary_token_threshold"].flatMap(Int.init) ?? 200
        )
    }

    private static func boolValue(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
}
