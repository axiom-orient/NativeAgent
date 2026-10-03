
struct ASKExportMetadataAttributes: Sendable {
    let escaper: ASKMarkupEscaper

    func sourceAttributes(anchor: ASKPageSourceAnchor?) -> [String] {
        guard let anchor else {
            return []
        }

        var attributes = ["data-source-id=\"\(escaper.escape(anchor.sourceID.rawValue))\""]
        if let fragment = anchor.fragment {
            attributes.append("data-source-fragment=\"\(escaper.escape(fragment))\"")
        }
        if let range = anchor.range {
            attributes.append("data-source-start=\"\(range.start)\"")
            attributes.append("data-source-end=\"\(range.end)\"")
        }
        return attributes
    }

    func semanticAttributes(role: ASKPageInlineSemanticRole?) -> [String] {
        guard let role else {
            return []
        }

        switch role {
        case .link:
            return ["data-semantic-role=\"link\""]
        case .citation(let identifier):
            return [
                "data-semantic-role=\"citation\"",
                "data-semantic-id=\"\(escaper.escape(identifier))\""
            ]
        case .entity(let identifier):
            return [
                "data-semantic-role=\"entity\"",
                "data-semantic-id=\"\(escaper.escape(identifier))\""
            ]
        }
    }

    func emphasisAttributes(_ emphasis: ASKPageInlineEmphasis) -> [String] {
        var attributes: [String] = []
        if emphasis.contains(.bold) { attributes.append("data-emphasis-bold=\"true\"") }
        if emphasis.contains(.italic) { attributes.append("data-emphasis-italic=\"true\"") }
        if emphasis.contains(.code) { attributes.append("data-emphasis-code=\"true\"") }
        return attributes
    }

    func destinationAttributes(_ destination: String?) -> [String] {
        guard let destination else {
            return []
        }
        return ["data-destination=\"\(escaper.escape(destination))\""]
    }

    func blockIDAttributes(_ blockID: ASKPageBlockID?) -> [String] {
        guard let blockID else {
            return []
        }
        return ["data-block-id=\"\(escaper.escape(blockID.rawValue))\""]
    }
}
