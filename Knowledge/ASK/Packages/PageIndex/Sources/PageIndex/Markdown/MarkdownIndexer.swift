import Foundation
import MarkdownSyntax

public protocol MarkdownSummaryGenerating: Sendable {
    func summary(for node: DocumentNode, model: String?) async throws -> String
}

public protocol MarkdownDescriptionGenerating: Sendable {
    func description(for structure: [DocumentNode], model: String?) async throws -> String
}

public struct PassThroughMarkdownSummaryGenerator: MarkdownSummaryGenerating, Sendable {
    public init() {}
    public func summary(for node: DocumentNode, model: String?) async throws -> String {
        node.text ?? ""
    }
}

public struct EmptyMarkdownDescriptionGenerator: MarkdownDescriptionGenerating, Sendable {
    public init() {}
    public func description(for structure: [DocumentNode], model: String?) async throws -> String {
        ""
    }
}

struct MarkdownHeaderMatch: Equatable, Sendable {
    let title: String
    let lineNumber: Int
    let level: Int
}

struct MarkdownFlatNode: Equatable, Sendable {
    var title: String
    var lineNumber: Int
    var level: Int
    var text: String
    var textTokenCount: Int?
    var isSyntheticRoot: Bool
}

enum MarkdownParser {
    static func extractNodesFromMarkdown(_ markdownContent: String) -> ([MarkdownHeaderMatch], [String]) {
        let normalizedMarkdown = normalizeLineEndings(markdownContent)
        let lines = normalizedMarkdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let outline = MarkdownSyntaxParser.outline(markdown: normalizedMarkdown)
        return (
            outline.sections.map {
                MarkdownHeaderMatch(title: $0.title, lineNumber: $0.startLine, level: $0.level)
            },
            lines
        )
    }

    static func normalizeLineEndings(_ markdownContent: String) -> String {
        markdownContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func extractNodeTextContent(_ nodeList: [MarkdownHeaderMatch], markdownLines: [String]) -> [MarkdownFlatNode] {
        var allNodes = nodeList.map {
            MarkdownFlatNode(
                title: $0.title,
                lineNumber: $0.lineNumber,
                level: $0.level,
                text: "",
                textTokenCount: nil,
                isSyntheticRoot: false
            )
        }
        for index in allNodes.indices {
            // Parser locations are external data. Keep a malformed location
            // from turning source indexing into an array-bounds crash.
            let startLine = min(max(allNodes[index].lineNumber - 1, 0), markdownLines.count)
            let requestedEndLine = (index + 1 < allNodes.count) ? (allNodes[index + 1].lineNumber - 1) : markdownLines.count
            let endLine = min(max(requestedEndLine, startLine), markdownLines.count)
            allNodes[index].text = markdownLines[startLine..<endLine].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return allNodes
    }

    static func updateNodeListWithTextTokenCount(_ nodeList: [MarkdownFlatNode], subtreeEndIndices: [Int], model: String?, tokenCounter: TokenCounting) -> [MarkdownFlatNode] {
        var result = nodeList
        for index in result.indices.reversed() {
            var totalText = result[index].text
            for childIndex in (index + 1)..<subtreeEndIndices[index] {
                let childText = result[childIndex].text
                if !childText.isEmpty { totalText += "\n" + childText }
            }
            result[index].textTokenCount = tokenCounter.countTokens(in: totalText, model: model)
        }
        return result
    }

    static func treeThinningForIndex(_ nodeList: [MarkdownFlatNode], subtreeEndIndices: [Int], minNodeToken: Int, model: String?, tokenCounter: TokenCounting) -> [MarkdownFlatNode] {
        var result = nodeList
        var nodesToRemove: Set<Int> = []
        for index in result.indices.reversed() {
            if nodesToRemove.contains(index) { continue }
            let totalTokens = result[index].textTokenCount ?? 0
            guard totalTokens < minNodeToken else { continue }
            var childrenTexts: [String] = []
            for childIndex in (index + 1)..<subtreeEndIndices[index] where !nodesToRemove.contains(childIndex) {
                let childText = result[childIndex].text
                if !childText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    childrenTexts.append(childText)
                }
                nodesToRemove.insert(childIndex)
            }
            guard !childrenTexts.isEmpty else { continue }
            var mergedText = result[index].text
            for childText in childrenTexts {
                if !mergedText.isEmpty && !mergedText.hasSuffix("\n") {
                    mergedText += "\n\n"
                }
                mergedText += childText
            }
            result[index].text = mergedText
            result[index].textTokenCount = tokenCounter.countTokens(in: mergedText, model: model)
        }
        for index in nodesToRemove.sorted(by: >) { result.remove(at: index) }
        return result
    }

    static func subtreeEndIndices(for nodeList: [MarkdownFlatNode]) -> [Int] {
        var endIndices = Array(repeating: nodeList.count, count: nodeList.count)
        var stack: [Int] = []
        for index in nodeList.indices {
            while let ancestorIndex = stack.last, nodeList[ancestorIndex].level >= nodeList[index].level {
                endIndices[ancestorIndex] = index
                stack.removeLast()
            }
            stack.append(index)
        }
        return endIndices
    }

    static func buildTreeFromNodes(_ nodeList: [MarkdownFlatNode]) -> [DocumentNode] {
        guard !nodeList.isEmpty else { return [] }
        var stack: [(path: [Int], level: Int)] = []
        var rootNodes: [DocumentNode] = []
        var nodeCounter = 1
        for node in nodeList {
            let treeNode = DocumentNode(title: node.title, nodeID: String(format: "%04d", nodeCounter), lineNumber: node.lineNumber, text: node.text, nodes: nil)
            nodeCounter += 1
            if node.isSyntheticRoot {
                rootNodes.append(treeNode)
                continue
            }
            while let last = stack.last, last.level >= node.level { stack.removeLast() }
            if let parent = stack.last {
                let insertionPath = parent.path + [childCount(at: parent.path, in: rootNodes)]
                rootNodes = append(node: treeNode, toNodeAt: parent.path, in: rootNodes)
                stack.append((path: insertionPath, level: node.level))
            } else {
                let path = [rootNodes.count]
                rootNodes.append(treeNode)
                stack.append((path: path, level: node.level))
            }
        }
        return rootNodes
    }

    private static func childCount(at path: [Int], in nodes: [DocumentNode]) -> Int {
        guard let parent = node(at: path, in: nodes) else { return 0 }
        return parent.nodes?.count ?? 0
    }

    private static func node(at path: [Int], in nodes: [DocumentNode]) -> DocumentNode? {
        guard let first = path.first, nodes.indices.contains(first) else { return nil }
        var current = nodes[first]
        for index in path.dropFirst() {
            guard let children = current.nodes, children.indices.contains(index) else { return nil }
            current = children[index]
        }
        return current
    }

    private static func append(node: DocumentNode, toNodeAt path: [Int], in nodes: [DocumentNode]) -> [DocumentNode] {
        guard let first = path.first, nodes.indices.contains(first) else { return nodes }
        var copy = nodes
        if path.count == 1 {
            var parent = copy[first]
            var children = parent.nodes ?? []
            children.append(node)
            parent.nodes = children
            copy[first] = parent
            return copy
        }
        var parent = copy[first]
        if let children = parent.nodes {
            parent.nodes = append(node: node, toNodeAt: Array(path.dropFirst()), in: children)
            copy[first] = parent
        }
        return copy
    }

}


public protocol MarkdownIndexing: Sendable {
    func index(
        markdownAt url: URL,
        options: ASKPageIndexOptions
    ) async throws -> IndexedDocument

    func index(
        markdownContent: String,
        sourceName: String,
        sourcePath: String?,
        options: ASKPageIndexOptions
    ) async throws -> IndexedDocument
}

public struct MarkdownIndexer: MarkdownIndexing, Sendable {
    private let tokenCounter: TokenCounting
    private let summaryGenerator: MarkdownSummaryGenerating
    private let descriptionGenerator: MarkdownDescriptionGenerating

    public init(tokenCounter: TokenCounting = WhitespaceTokenCounter(), summaryGenerator: MarkdownSummaryGenerating = PassThroughMarkdownSummaryGenerator(), descriptionGenerator: MarkdownDescriptionGenerating = EmptyMarkdownDescriptionGenerator()) {
        self.tokenCounter = tokenCounter
        self.summaryGenerator = summaryGenerator
        self.descriptionGenerator = descriptionGenerator
    }

    public func index(markdownAt url: URL, options: ASKPageIndexOptions) async throws -> IndexedDocument {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw ASKPageIndexError.fileNotFound(url.path)
        }
        return try await index(markdownContent: content, sourceName: url.deletingPathExtension().lastPathComponent, sourcePath: url.path, options: options)
    }

    public func index(markdownAt url: URL, options: ASKPageIndexOptions, ifThinning: Bool, minTokenThreshold: Int?, summaryTokenThreshold: Int) async throws -> IndexedDocument {
        var updatedOptions = options
        updatedOptions.ifThinning = ifThinning
        updatedOptions.minTokenThreshold = minTokenThreshold
        updatedOptions.summaryTokenThreshold = summaryTokenThreshold
        return try await index(markdownAt: url, options: updatedOptions)
    }

    public func index(markdownContent: String, sourceName: String, sourcePath: String? = nil, options: ASKPageIndexOptions) async throws -> IndexedDocument {
        let normalizedMarkdown = MarkdownParser.normalizeLineEndings(markdownContent)
        let outline = MarkdownSyntaxParser.outline(markdown: normalizedMarkdown, source: sourcePath.map(URL.init(fileURLWithPath:)))
        let lineCount = outline.lineCount
        let (nodeMatches, markdownLines) = MarkdownParser.extractNodesFromMarkdown(normalizedMarkdown)
        var nodesWithContent = MarkdownParser.extractNodeTextContent(nodeMatches, markdownLines: markdownLines)
        if outline.isHeaderless {
            nodesWithContent = [
                MarkdownFlatNode(
                    title: "(document)",
                    lineNumber: 1,
                    level: 1,
                    text: normalizedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines),
                    textTokenCount: nil,
                    isSyntheticRoot: true
                ),
            ]
        } else if let preamble = outline.preambleRange {
            let preambleText = markdownLines[(preamble.startLine - 1)..<preamble.endLine]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preambleNode = MarkdownFlatNode(
                title: "(preamble)",
                lineNumber: preamble.startLine,
                level: 1,
                text: preambleText,
                textTokenCount: nil,
                isSyntheticRoot: true
            )
            nodesWithContent.insert(preambleNode, at: 0)
        }
        if options.ifThinning {
            guard let minTokenThreshold = options.minTokenThreshold else { throw ASKPageIndexError.invalidArguments("minTokenThreshold must be provided when thinning is enabled") }
            let subtreeEndIndices = MarkdownParser.subtreeEndIndices(for: nodesWithContent)
            nodesWithContent = MarkdownParser.updateNodeListWithTextTokenCount(nodesWithContent, subtreeEndIndices: subtreeEndIndices, model: options.model, tokenCounter: tokenCounter)
            nodesWithContent = MarkdownParser.treeThinningForIndex(nodesWithContent, subtreeEndIndices: subtreeEndIndices, minNodeToken: minTokenThreshold, model: options.model, tokenCounter: tokenCounter)
        }
        var treeStructure = MarkdownParser.buildTreeFromNodes(nodesWithContent)
        if options.ifAddNodeID.boolValue {
            treeStructure = DocumentTreeUtilities.assignNodeIDs(treeStructure, startingAt: 0)
        }
        if options.ifAddNodeSummary.boolValue {
            treeStructure = try await applySummaries(to: treeStructure, summaryTokenThreshold: options.summaryTokenThreshold, model: options.model)
            let docDescription: String?
            if options.ifAddDocDescription.boolValue {
                docDescription = try await descriptionGenerator.description(for: DocumentTreeUtilities.createCleanStructureForDescription(treeStructure), model: options.model)
            } else {
                docDescription = nil
            }
            if !options.ifAddNodeText.boolValue {
                treeStructure = DocumentTreeUtilities.removeText(treeStructure)
            }
            return IndexedDocument(type: .md, path: sourcePath, docName: sourceName, docDescription: docDescription, lineCount: lineCount, structure: treeStructure)
        }
        if !options.ifAddNodeText.boolValue {
            treeStructure = DocumentTreeUtilities.removeText(treeStructure)
        }
        return IndexedDocument(type: .md, path: sourcePath, docName: sourceName, lineCount: lineCount, structure: treeStructure)
    }

    public func index(markdownContent: String, sourceName: String, sourcePath: String? = nil, options: ASKPageIndexOptions, ifThinning: Bool, minTokenThreshold: Int?, summaryTokenThreshold: Int) async throws -> IndexedDocument {
        var updatedOptions = options
        updatedOptions.ifThinning = ifThinning
        updatedOptions.minTokenThreshold = minTokenThreshold
        updatedOptions.summaryTokenThreshold = summaryTokenThreshold
        return try await index(markdownContent: markdownContent, sourceName: sourceName, sourcePath: sourcePath, options: updatedOptions)
    }

    private func applySummaries(to nodes: [DocumentNode], summaryTokenThreshold: Int, model: String?) async throws -> [DocumentNode] {
        var result: [DocumentNode] = []
        result.reserveCapacity(nodes.count)
        for node in nodes {
            var copy = node
            if let children = copy.nodes, !children.isEmpty {
                copy.nodes = try await applySummaries(to: children, summaryTokenThreshold: summaryTokenThreshold, model: model)
            }
            let summary = try await summaryText(for: copy, summaryTokenThreshold: summaryTokenThreshold, model: model)
            if copy.isLeaf { copy.summary = summary } else { copy.prefixSummary = summary }
            result.append(copy)
        }
        return result
    }

    private func summaryText(for node: DocumentNode, summaryTokenThreshold: Int, model: String?) async throws -> String {
        let nodeText = node.text ?? ""
        let tokenCount = tokenCounter.countTokens(in: nodeText, model: model)
        if tokenCount < summaryTokenThreshold { return nodeText }
        return try await summaryGenerator.summary(for: node, model: model)
    }
}
