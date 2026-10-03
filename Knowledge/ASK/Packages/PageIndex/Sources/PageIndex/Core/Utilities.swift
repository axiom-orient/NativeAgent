import Foundation

public enum PageRangeParser {
    public static func parse(_ pages: String) throws -> [Int] {
        let parts = pages.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            throw ASKPageIndexError.invalidPagesFormat(pages)
        }

        var result: Set<Int> = []
        for rawPart in parts {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            if part.contains("-") {
                let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start <= end else {
                    throw ASKPageIndexError.invalidPagesFormat(pages)
                }
                result.formUnion(start...end)
            } else {
                guard let page = Int(part) else {
                    throw ASKPageIndexError.invalidPagesFormat(pages)
                }
                result.insert(page)
            }
        }
        return result.sorted()
    }
}

public enum JSONEncoderFactory {
    public static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        return encoder
    }

    public static func encodeToString<T: Encodable>(_ value: T, prettyPrinted: Bool = false) throws -> String {
        let data = try makeEncoder(prettyPrinted: prettyPrinted).encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum DocumentTreeUtilities {
    public static func flatten(_ nodes: [DocumentNode]) -> [DocumentNode] {
        var result: [DocumentNode] = []
        for node in nodes {
            result.append(node)
            if let children = node.nodes {
                result.append(contentsOf: flatten(children))
            }
        }
        return result
    }

    public static func leafNodes(_ nodes: [DocumentNode]) -> [DocumentNode] {
        var result: [DocumentNode] = []
        for node in nodes {
            if let children = node.nodes, !children.isEmpty {
                result.append(contentsOf: leafNodes(children))
            } else {
                result.append(node)
            }
        }
        return result
    }

    public static func createNodeMapping(_ nodes: [DocumentNode]) -> [String: DocumentNode] {
        var mapping: [String: DocumentNode] = [:]
        for node in flatten(nodes) {
            if let nodeID = node.nodeID {
                mapping[nodeID] = node
            }
        }
        return mapping
    }

    public static func assignNodeIDs(_ nodes: [DocumentNode], startingAt start: Int = 0) -> [DocumentNode] {
        var nextID = start
        return assignNodeIDs(nodes, nextID: &nextID)
    }

    private static func assignNodeIDs(_ nodes: [DocumentNode], nextID: inout Int) -> [DocumentNode] {
        nodes.map { node in
            var copy = node
            copy.nodeID = String(format: "%04d", nextID)
            nextID += 1
            if let children = copy.nodes, !children.isEmpty {
                copy.nodes = assignNodeIDs(children, nextID: &nextID)
            }
            if copy.nodes?.isEmpty == true {
                copy.nodes = nil
            }
            return copy
        }
    }

    public static func removeText(_ nodes: [DocumentNode]) -> [DocumentNode] {
        nodes.map { node in
            var copy = node
            copy.text = nil
            if let children = copy.nodes {
                copy.nodes = removeText(children)
            }
            if copy.nodes?.isEmpty == true {
                copy.nodes = nil
            }
            return copy
        }
    }

    public static func createCleanStructureForDescription(_ nodes: [DocumentNode]) -> [DocumentNode] {
        nodes.map { node in
            var copy = DocumentNode(
                title: node.title,
                nodeID: node.nodeID,
                summary: node.summary,
                prefixSummary: node.prefixSummary,
                nodes: nil
            )
            if let children = node.nodes, !children.isEmpty {
                copy.nodes = createCleanStructureForDescription(children)
            }
            return copy
        }
    }

    public static func removingEmptyChildren(_ nodes: [DocumentNode]) -> [DocumentNode] {
        nodes.map { node in
            var copy = node
            if let children = copy.nodes {
                copy.nodes = removingEmptyChildren(children)
            }
            if copy.nodes?.isEmpty == true {
                copy.nodes = nil
            }
            return copy
        }
    }
}

