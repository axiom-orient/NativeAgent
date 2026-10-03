import Foundation

public struct SourceCorpusScope: Codable, Sendable, Equatable {
    public var types: [DocumentType]
    public var pathPrefixes: [String]
    public var maxSources: Int

    public init(types: [DocumentType] = [], pathPrefixes: [String] = [], maxSources: Int = 12) {
        self.types = types
        self.pathPrefixes = pathPrefixes
        self.maxSources = maxSources
    }
}

public enum SourceSelection: Codable, Sendable, Equatable {
    case exact(sourceIDs: [SourceID])
    case scoped(corpusScope: SourceCorpusScope)
}

public struct SourceEvidenceQuery: Codable, Sendable, Equatable {
    public var sourceSelection: SourceSelection
    public var question: String
    public var maxTreeDepth: Int
    public var maxVisitedNodes: Int
    public var maxRawEvidenceTokens: Int
    public var maxModelCalls: Int

    public init(
        sourceSelection: SourceSelection,
        question: String,
        maxTreeDepth: Int = 3,
        maxVisitedNodes: Int = 12,
        maxRawEvidenceTokens: Int = 2_400,
        maxModelCalls: Int = 4
    ) {
        self.sourceSelection = sourceSelection
        self.question = question
        self.maxTreeDepth = maxTreeDepth
        self.maxVisitedNodes = maxVisitedNodes
        self.maxRawEvidenceTokens = maxRawEvidenceTokens
        self.maxModelCalls = maxModelCalls
    }

    public func validate() throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKPageIndexError.invalidArguments("source evidence query question must not be empty")
        }
        guard maxTreeDepth > 0, maxVisitedNodes > 0, maxRawEvidenceTokens > 0, maxModelCalls >= 0 else {
            throw ASKPageIndexError.invalidArguments("source evidence query limits must be positive, except maxModelCalls may be zero")
        }
        switch sourceSelection {
        case .exact(let sourceIDs):
            guard !sourceIDs.isEmpty, Set(sourceIDs).count == sourceIDs.count else {
                throw ASKPageIndexError.invalidArguments("exact source selection must be non-empty and unique")
            }
        case .scoped(let scope):
            guard scope.maxSources > 0 else {
                throw ASKPageIndexError.invalidArguments("corpus maxSources must be positive")
            }
        }
    }
}

public enum SourceEvidenceAnswerability: String, Codable, Sendable {
    case sufficient
    case insufficient
    case extractionBlocked
}

public struct EvidenceExcerpt: Codable, Sendable, Equatable {
    public var anchor: SourceAnchor
    public var index: Int
    public var content: String

    public init(anchor: SourceAnchor, index: Int, content: String) {
        self.anchor = anchor
        self.index = index
        self.content = content
    }
}

public struct VectorlessRAGTrace: Codable, Sendable, Equatable {
    public var selectedSourceIDs: [SourceID]
    public var visitedNodeIDs: [String]
    public var modelCalls: Int
    public var rawEvidenceTokens: Int
    public var diagnostics: [String]

    public init(
        selectedSourceIDs: [SourceID],
        visitedNodeIDs: [String],
        modelCalls: Int,
        rawEvidenceTokens: Int,
        diagnostics: [String]
    ) {
        self.selectedSourceIDs = selectedSourceIDs
        self.visitedNodeIDs = visitedNodeIDs
        self.modelCalls = modelCalls
        self.rawEvidenceTokens = rawEvidenceTokens
        self.diagnostics = diagnostics
    }
}

public struct SourceEvidenceResult: Codable, Sendable, Equatable {
    public var answerability: SourceEvidenceAnswerability
    public var anchors: [SourceAnchor]
    public var excerpts: [EvidenceExcerpt]
    public var trace: VectorlessRAGTrace

    public init(
        answerability: SourceEvidenceAnswerability,
        anchors: [SourceAnchor],
        excerpts: [EvidenceExcerpt],
        trace: VectorlessRAGTrace
    ) {
        self.answerability = answerability
        self.anchors = anchors
        self.excerpts = excerpts
        self.trace = trace
    }
}

public enum VectorlessNavigationStage: String, Codable, Sendable {
    case corpus
    case document
}

public struct VectorlessNavigationCandidate: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var summary: String?
    public var sourceID: SourceID
    public var sourceVersionChecksum: String

    public init(id: String, title: String, summary: String?, sourceID: SourceID, sourceVersionChecksum: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.sourceID = sourceID
        self.sourceVersionChecksum = sourceVersionChecksum
    }
}

public struct VectorlessNavigationPrompt: Codable, Sendable, Equatable {
    public var stage: VectorlessNavigationStage
    public var question: String
    public var candidates: [VectorlessNavigationCandidate]
    public var remainingDepth: Int
    public var remainingVisits: Int

    public init(
        stage: VectorlessNavigationStage,
        question: String,
        candidates: [VectorlessNavigationCandidate],
        remainingDepth: Int,
        remainingVisits: Int
    ) {
        self.stage = stage
        self.question = question
        self.candidates = candidates
        self.remainingDepth = remainingDepth
        self.remainingVisits = remainingVisits
    }
}

/// Host-owned model transport. The host may implement this with an LLM, but the
/// PageIndex package accepts only a JSON selection and validates every ID before
/// it ever reads an excerpt.
public protocol VectorlessTreeNavigating: Sendable {
    /// Number of provider-model calls represented by one `chooseJSON` request.
    /// A deterministic local navigator reports zero while an LLM-backed host
    /// uses the default cost of one. This keeps the trace honest without
    /// weakening depth/visit bounds for model-free traversal.
    var modelCallCost: Int { get }
    func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String
}

public extension VectorlessTreeNavigating {
    var modelCallCost: Int { 1 }
}

/// Model-free fallback used for local/offline retrieval and deterministic tests.
public struct LexicalTreeNavigator: VectorlessTreeNavigating, Sendable {
    public init() {}

    public var modelCallCost: Int { 0 }

    public func chooseJSON(for prompt: VectorlessNavigationPrompt) async throws -> String {
        let queryTerms = Set(tokens(prompt.question))
        let ranked = prompt.candidates
            .map { candidate in
                let haystack = tokens(candidate.title + " " + (candidate.summary ?? ""))
                return (candidate, haystack.reduce(0) { $0 + (queryTerms.contains($1) ? 1 : 0) })
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.id < rhs.0.id
            }
        let limit = max(0, prompt.remainingVisits)
        let chosen = ranked.prefix(limit).map(\.0)
        let choice = NavigatorChoice(
            sourceIDs: prompt.stage == .corpus ? chosen.map { $0.sourceID.rawValue } : [],
            nodeIDs: prompt.stage == .document ? chosen.map(\.id) : [],
            sufficient: !chosen.isEmpty
        )
        return String(decoding: try JSONEncoder().encode(choice), as: UTF8.self)
    }

    private func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

public struct VectorlessTreeRAG: Sendable {
    private let navigator: any VectorlessTreeNavigating

    public init(navigator: any VectorlessTreeNavigating = LexicalTreeNavigator()) {
        self.navigator = navigator
    }

    public func retrieve(
        query: SourceEvidenceQuery,
        artifacts: [SourceIndexArtifact]
    ) async throws -> SourceEvidenceResult {
        try query.validate()
        guard Set(artifacts.map { $0.document.sourceID }).count == artifacts.count else {
            throw ASKPageIndexError.invalidArguments(
                "source evidence artifacts contain duplicate source IDs")
        }
        for artifact in artifacts {
            try SourceIndexArtifactValidator.validate(artifact)
        }
        var diagnostics: [String] = []
        var modelCalls = 0
        var selectedArtifacts = try await selectArtifacts(
            query: query,
            artifacts: artifacts,
            modelCalls: &modelCalls,
            diagnostics: &diagnostics
        )
        selectedArtifacts.sort { $0.document.sourceID.rawValue < $1.document.sourceID.rawValue }
        if diagnostics.contains("one or more exact sources are unavailable") {
            return result(
                answerability: .insufficient,
                selected: selectedArtifacts,
                visited: [],
                modelCalls: modelCalls,
                evidence: [],
                diagnostics: diagnostics
            )
        }
        let blockedArtifacts = selectedArtifacts.filter { $0.extractionQuality.blocksEvidenceRetrieval }
        if !blockedArtifacts.isEmpty {
            diagnostics.append("source extraction is blocked: \(blockedArtifacts.map { $0.document.sourceID.rawValue }.sorted().joined(separator: ","))")
            return result(
                answerability: .extractionBlocked,
                selected: selectedArtifacts,
                visited: [],
                modelCalls: modelCalls,
                evidence: [],
                diagnostics: diagnostics
            )
        }
        for artifact in selectedArtifacts where artifact.extractionQuality == .layoutUncertain {
            diagnostics.append("source layout extraction is uncertain: \(artifact.document.sourceID.rawValue)")
        }
        guard !selectedArtifacts.isEmpty else {
            return result(
                answerability: .insufficient,
                selected: [],
                visited: [],
                modelCalls: modelCalls,
                evidence: [],
                diagnostics: diagnostics + ["no source selected"]
            )
        }

        var visited: [VisitedNode] = []
        var evidence: [EvidenceExcerpt] = []
        var rawTokens = 0
        for artifact in selectedArtifacts {
            guard !artifact.document.rootNodes.isEmpty else {
                diagnostics.append("source \(artifact.document.sourceID.rawValue) has no index nodes")
                continue
            }
            var candidates = artifact.document.rootNodes
            var selectedLeaf = false
            for depth in 0..<query.maxTreeDepth {
                guard !candidates.isEmpty else { break }
                guard visited.count < query.maxVisitedNodes else {
                    diagnostics.append("node visit cap reached")
                    return result(
                        answerability: .insufficient,
                        selected: selectedArtifacts,
                        visited: visited,
                        modelCalls: modelCalls,
                        evidence: evidence,
                        diagnostics: diagnostics,
                        rawTokens: rawTokens
                    )
                }
                guard permitsNextNavigation(query: query, modelCalls: modelCalls) else {
                    diagnostics.append("model call cap reached")
                    return result(
                        answerability: .insufficient,
                        selected: selectedArtifacts,
                        visited: visited,
                        modelCalls: modelCalls,
                        evidence: evidence,
                        diagnostics: diagnostics,
                        rawTokens: rawTokens
                    )
                }
                let prompt = VectorlessNavigationPrompt(
                    stage: .document,
                    question: query.question,
                    candidates: candidates.map { candidate(for: $0, artifact: artifact) },
                    remainingDepth: query.maxTreeDepth - depth,
                    remainingVisits: query.maxVisitedNodes - visited.count
                )
                let choice = try await choose(
                    prompt: prompt,
                    modelCalls: &modelCalls,
                    diagnostics: &diagnostics
                )
                let available = Dictionary(uniqueKeysWithValues: candidates.map { ($0.nodeID, $0) })
                guard choice.sufficient else {
                    diagnostics.append("navigator marked document evidence insufficient")
                    return result(
                        answerability: .insufficient,
                        selected: selectedArtifacts,
                        visited: visited,
                        modelCalls: modelCalls,
                        evidence: [],
                        diagnostics: diagnostics
                    )
                }
                guard choice.sourceIDs.isEmpty else {
                    diagnostics.append("navigator selected source IDs during document navigation")
                    return result(
                        answerability: .insufficient,
                        selected: selectedArtifacts,
                        visited: visited,
                        modelCalls: modelCalls,
                        evidence: [],
                        diagnostics: diagnostics
                    )
                }
                let chosenIDs = unique(choice.nodeIDs)
                guard chosenIDs.count == choice.nodeIDs.count else {
                    diagnostics.append("navigator selected duplicate document node")
                    return result(
                        answerability: .insufficient,
                        selected: selectedArtifacts,
                        visited: visited,
                        modelCalls: modelCalls,
                        evidence: [],
                        diagnostics: diagnostics
                    )
                }
                guard chosenIDs.allSatisfy({ available[$0] != nil }) else {
                    diagnostics.append("navigator selected unknown document node")
                    return result(
                        answerability: .insufficient,
                        selected: selectedArtifacts,
                        visited: visited,
                        modelCalls: modelCalls,
                        evidence: [],
                        diagnostics: diagnostics
                    )
                }
                guard !chosenIDs.isEmpty else {
                    diagnostics.append("navigator selected no document node")
                    return result(
                        answerability: .insufficient,
                        selected: selectedArtifacts,
                        visited: visited,
                        modelCalls: modelCalls,
                        evidence: [],
                        diagnostics: diagnostics
                    )
                }
                guard chosenIDs.count <= query.maxVisitedNodes - visited.count else {
                    diagnostics.append("node visit cap reached")
                    return result(
                        answerability: .insufficient,
                        selected: selectedArtifacts,
                        visited: visited,
                        modelCalls: modelCalls,
                        evidence: evidence,
                        diagnostics: diagnostics,
                        rawTokens: rawTokens
                    )
                }
                let nodes = chosenIDs.compactMap { available[$0] }
                for node in nodes {
                    visited.append(VisitedNode(artifact: artifact, node: node))
                }
                let next = nodes.flatMap(\.children)
                if next.isEmpty || depth + 1 == query.maxTreeDepth {
                    for node in nodes {
                        let opened = try appendEvidence(
                            artifact: artifact,
                            node: node,
                            budget: query.maxRawEvidenceTokens,
                            rawTokens: &rawTokens,
                            evidence: &evidence
                        )
                        guard opened else {
                            diagnostics.append("raw evidence token cap reached")
                            return result(
                                answerability: .insufficient,
                                selected: selectedArtifacts,
                                visited: visited,
                                modelCalls: modelCalls,
                                evidence: evidence,
                                diagnostics: diagnostics,
                                rawTokens: rawTokens
                            )
                        }
                        selectedLeaf = true
                    }
                    break
                }
                candidates = next
            }
            if !selectedLeaf {
                diagnostics.append("source \(artifact.document.sourceID.rawValue) did not reach an openable node")
            }
        }

        let answerability: SourceEvidenceAnswerability = evidence.isEmpty ? .insufficient : .sufficient
        return result(
            answerability: answerability,
            selected: selectedArtifacts,
            visited: visited,
            modelCalls: modelCalls,
            evidence: evidence,
            diagnostics: diagnostics,
            rawTokens: rawTokens
        )
    }

    private func selectArtifacts(
        query: SourceEvidenceQuery,
        artifacts: [SourceIndexArtifact],
        modelCalls: inout Int,
        diagnostics: inout [String]
    ) async throws -> [SourceIndexArtifact] {
        switch query.sourceSelection {
        case .exact(let sourceIDs):
            let byID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.document.sourceID, $0) })
            let selected = sourceIDs.compactMap { byID[$0] }
            if selected.count != sourceIDs.count { diagnostics.append("one or more exact sources are unavailable") }
            return selected
        case .scoped(let scope):
            let scoped = artifacts.filter { artifact in
                (scope.types.isEmpty || scope.types.contains(artifact.document.type))
                    && (scope.pathPrefixes.isEmpty || scope.pathPrefixes.contains { prefix in
                        artifact.sourcePath.map { pathMatchesPrefix($0, prefix: prefix) } ?? false
                    })
            }
            guard !scoped.isEmpty else { return [] }
            guard permitsNextNavigation(query: query, modelCalls: modelCalls) else {
                diagnostics.append("model call cap reached before corpus selection")
                return []
            }
            let prompt = VectorlessNavigationPrompt(
                stage: .corpus,
                question: query.question,
                candidates: scoped.map(corpusCandidate),
                remainingDepth: query.maxTreeDepth,
                remainingVisits: min(query.maxVisitedNodes, scope.maxSources)
            )
            let choice = try await choose(prompt: prompt, modelCalls: &modelCalls, diagnostics: &diagnostics)
            guard choice.sufficient else {
                diagnostics.append("navigator marked corpus selection insufficient")
                return []
            }
            guard choice.nodeIDs.isEmpty else {
                diagnostics.append("navigator selected node IDs during corpus navigation")
                return []
            }
            let available = Dictionary(uniqueKeysWithValues: scoped.map { ($0.document.sourceID.rawValue, $0) })
            let sourceIDs = unique(choice.sourceIDs)
            guard sourceIDs.count == choice.sourceIDs.count else {
                diagnostics.append("navigator selected duplicate corpus source")
                return []
            }
            guard sourceIDs.allSatisfy({ available[$0] != nil }) else {
                diagnostics.append("navigator selected source outside corpus scope")
                return []
            }
            guard sourceIDs.count <= scope.maxSources else {
                diagnostics.append("navigator selected more sources than corpus limit")
                return []
            }
            return sourceIDs.compactMap { available[$0] }
        }
    }

    private func pathMatchesPrefix(_ path: String, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        var trimmedPrefix = prefix
        while trimmedPrefix.count > 1 && trimmedPrefix.hasSuffix("/") {
            trimmedPrefix.removeLast()
        }
        if trimmedPrefix.isEmpty {
            return path.hasPrefix("/")
        }
        if trimmedPrefix == "/" {
            return path.hasPrefix("/")
        }
        return path == trimmedPrefix || path.hasPrefix(trimmedPrefix + "/")
    }

    private func choose(
        prompt: VectorlessNavigationPrompt,
        modelCalls: inout Int,
        diagnostics: inout [String]
    ) async throws -> NavigatorChoice {
        let callCost = max(0, navigator.modelCallCost)
        guard callCost <= Int.max - modelCalls else {
            throw ASKPageIndexError.invalidArguments("navigator model call cost exceeds trace range")
        }
        modelCalls += callCost
        let raw: String
        do {
            raw = try await navigator.chooseJSON(for: prompt)
        } catch {
            diagnostics.append("navigator failed: \(String(describing: error))")
            return NavigatorChoice(sourceIDs: [], nodeIDs: [], sufficient: false)
        }
        do {
            return try decodeStrictChoice(raw)
        } catch {
            diagnostics.append("navigator emitted invalid JSON selection")
            return NavigatorChoice(sourceIDs: [], nodeIDs: [], sufficient: false)
        }
    }

    private func appendEvidence(
        artifact: SourceIndexArtifact,
        node: SourceIndexNode,
        budget: Int,
        rawTokens: inout Int,
        evidence: inout [EvidenceExcerpt]
    ) throws -> Bool {
        guard let anchor = SourceIndexNavigator.makeAnchor(
            sourceID: artifact.document.sourceID,
            nodeID: node.nodeID,
            in: artifact
        ) else { return false }
        let excerpts = artifact.excerpts.filter { node.range.contains($0.index) }
        guard !excerpts.isEmpty else { return false }
        for excerpt in excerpts {
            let tokenCount = excerpt.content.split { $0.isWhitespace || $0.isNewline }.count
            guard rawTokens >= 0, rawTokens <= budget,
                  tokenCount <= budget - rawTokens
            else { return false }
            rawTokens += tokenCount
            evidence.append(EvidenceExcerpt(anchor: anchor, index: excerpt.index, content: excerpt.content))
        }
        return true
    }

    private func result(
        answerability: SourceEvidenceAnswerability,
        selected: [SourceIndexArtifact],
        visited: [VisitedNode],
        modelCalls: Int,
        evidence: [EvidenceExcerpt],
        diagnostics: [String],
        rawTokens: Int = 0
    ) -> SourceEvidenceResult {
        let anchors = Array(Set(evidence.map(\.anchor))).sorted { lhs, rhs in
            if lhs.sourceID != rhs.sourceID { return lhs.sourceID.rawValue < rhs.sourceID.rawValue }
            return lhs.nodeID < rhs.nodeID
        }
        return SourceEvidenceResult(
            answerability: answerability,
            anchors: anchors,
            excerpts: evidence,
            trace: VectorlessRAGTrace(
                selectedSourceIDs: selected.map { $0.document.sourceID }.sorted { $0.rawValue < $1.rawValue },
                visitedNodeIDs: visited.map { $0.node.nodeID },
                modelCalls: modelCalls,
                rawEvidenceTokens: rawTokens,
                diagnostics: diagnostics
            )
        )
    }

    private func corpusCandidate(_ artifact: SourceIndexArtifact) -> VectorlessNavigationCandidate {
        let description = artifact.document.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = description.flatMap { $0.isEmpty ? nil : $0 } ?? String(
            artifact.document.rootNodes.map { $0.title + " " + ($0.summary ?? $0.snippet ?? "") }
                .joined(separator: "\n").prefix(4_096)
        )
        return VectorlessNavigationCandidate(
            id: artifact.document.sourceID.rawValue,
            title: artifact.document.title,
            summary: summary,
            sourceID: artifact.document.sourceID,
            sourceVersionChecksum: artifact.version.checksum
        )
    }

    private func candidate(for node: SourceIndexNode, artifact: SourceIndexArtifact) -> VectorlessNavigationCandidate {
        VectorlessNavigationCandidate(
            id: node.nodeID,
            title: node.title,
            summary: node.summary ?? node.snippet,
            sourceID: artifact.document.sourceID,
            sourceVersionChecksum: artifact.version.checksum
        )
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func permitsNextNavigation(query: SourceEvidenceQuery, modelCalls: Int) -> Bool {
        guard modelCalls >= 0, modelCalls <= query.maxModelCalls else { return false }
        return max(0, navigator.modelCallCost) <= query.maxModelCalls - modelCalls
    }
}

private struct NavigatorChoice: Codable {
    let sourceIDs: [String]
    let nodeIDs: [String]
    let sufficient: Bool

    private enum CodingKeys: String, CodingKey {
        case sourceIDs = "source_ids"
        case nodeIDs = "node_ids"
        case sufficient
    }
}

private struct VisitedNode {
    let artifact: SourceIndexArtifact
    let node: SourceIndexNode
}

private func decodeStrictChoice(_ raw: String) throws -> NavigatorChoice {
    guard let data = raw.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == ["source_ids", "node_ids", "sufficient"]
    else {
        throw ASKPageIndexError.invalidArguments("invalid navigator JSON schema")
    }
    return try JSONDecoder().decode(NavigatorChoice.self, from: data)
}
