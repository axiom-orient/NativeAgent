import Foundation

public enum ASKWorkWikiKnowledgeCategory: String, CaseIterable, Codable, Sendable {
    case research
    case prepare
    case prove
    case docs
    case onit
}

public enum ASKWorkWikiProjectResolutionSource: String, Codable, Sendable {
    case workspaceHash = "workspace_hash"
}

public struct ASKWorkWikiProjectResolution: Codable, Equatable, Sendable {
    public var projectRootPath: String
    public var projectSlug: String
    public var source: ASKWorkWikiProjectResolutionSource

    public init(projectRootPath: String, projectSlug: String, source: ASKWorkWikiProjectResolutionSource) {
        self.projectRootPath = projectRootPath
        self.projectSlug = projectSlug
        self.source = source
    }
}

public struct ASKWorkWikiKnowledgeCounts: Codable, Equatable, Sendable {
    public var research: Int
    public var prepare: Int
    public var prove: Int
    public var docs: Int
    public var onit: Int

    public init(research: Int = 0, prepare: Int = 0, prove: Int = 0, docs: Int = 0, onit: Int = 0) {
        self.research = research
        self.prepare = prepare
        self.prove = prove
        self.docs = docs
        self.onit = onit
    }

    public var total: Int {
        research + prepare + prove + docs + onit
    }

    public subscript(_ category: ASKWorkWikiKnowledgeCategory) -> Int {
        get {
            switch category {
            case .research: research
            case .prepare: prepare
            case .prove: prove
            case .docs: docs
            case .onit: onit
            }
        }
        set {
            switch category {
            case .research: research = newValue
            case .prepare: prepare = newValue
            case .prove: prove = newValue
            case .docs: docs = newValue
            case .onit: onit = newValue
            }
        }
    }
}

public struct ASKWorkWikiKnowledgeStatus: Codable, Equatable, Sendable {
    public var project: ASKWorkWikiProjectResolution
    public var counts: ASKWorkWikiKnowledgeCounts
    public var indexedPaths: [String]

    public init(project: ASKWorkWikiProjectResolution, counts: ASKWorkWikiKnowledgeCounts, indexedPaths: [String]) {
        self.project = project
        self.counts = counts
        self.indexedPaths = indexedPaths
    }
}

public struct ASKWorkWikiKnowledgeDocumentSummary: Codable, Equatable, Sendable {
    public var relativePath: String
    public var category: ASKWorkWikiKnowledgeCategory
    public var title: String

    public init(relativePath: String, category: ASKWorkWikiKnowledgeCategory, title: String) {
        self.relativePath = relativePath
        self.category = category
        self.title = title
    }
}

public struct ASKWorkWikiKnowledgeDocument: Codable, Equatable, Sendable {
    public var relativePath: String
    public var category: ASKWorkWikiKnowledgeCategory
    public var title: String
    public var body: String

    public init(relativePath: String, category: ASKWorkWikiKnowledgeCategory, title: String, body: String) {
        self.relativePath = relativePath
        self.category = category
        self.title = title
        self.body = body
    }
}

public struct ASKWorkWikiKnowledgeSearchHit: Codable, Equatable, Sendable {
    public var relativePath: String
    public var category: ASKWorkWikiKnowledgeCategory
    public var title: String
    public var snippet: String
    public var score: Int

    public init(relativePath: String, category: ASKWorkWikiKnowledgeCategory, title: String, snippet: String, score: Int) {
        self.relativePath = relativePath
        self.category = category
        self.title = title
        self.snippet = snippet
        self.score = score
    }
}

public struct ASKWorkWikiKnowledgeSearchResult: Codable, Equatable, Sendable {
    public var project: ASKWorkWikiProjectResolution
    public var query: String
    public var hits: [ASKWorkWikiKnowledgeSearchHit]

    public init(project: ASKWorkWikiProjectResolution, query: String, hits: [ASKWorkWikiKnowledgeSearchHit]) {
        self.project = project
        self.query = query
        self.hits = hits
    }
}

public enum ASKWorkWikiConvergenceStrength: String, Codable, Sendable {
    case weak
    case partial
    case full
}

public struct ASKWorkWikiConvergenceTopic: Codable, Equatable, Sendable {
    public var topicSlug: String
    public var topicTitle: String
    public var researchCount: Int
    public var prepareCount: Int
    public var proveCount: Int
    public var docsCount: Int
    public var coveragePercent: Int
    public var strength: ASKWorkWikiConvergenceStrength

    public init(
        topicSlug: String,
        topicTitle: String,
        researchCount: Int,
        prepareCount: Int,
        proveCount: Int,
        docsCount: Int,
        coveragePercent: Int,
        strength: ASKWorkWikiConvergenceStrength
    ) {
        self.topicSlug = topicSlug
        self.topicTitle = topicTitle
        self.researchCount = researchCount
        self.prepareCount = prepareCount
        self.proveCount = proveCount
        self.docsCount = docsCount
        self.coveragePercent = coveragePercent
        self.strength = strength
    }
}

public struct ASKWorkWikiConvergenceReport: Codable, Equatable, Sendable {
    public var project: ASKWorkWikiProjectResolution
    public var topics: [ASKWorkWikiConvergenceTopic]

    public init(project: ASKWorkWikiProjectResolution, topics: [ASKWorkWikiConvergenceTopic]) {
        self.project = project
        self.topics = topics
    }
}

public enum ASKWorkWikiCapabilitySupport: String, Codable, Sendable {
    case supported
    case partial
    case unsupported
}

public struct ASKWorkWikiCapability: Codable, Equatable, Sendable {
    public var name: String
    public var support: ASKWorkWikiCapabilitySupport
    public var reason: String

    public init(name: String, support: ASKWorkWikiCapabilitySupport, reason: String) {
        self.name = name
        self.support = support
        self.reason = reason
    }
}

public struct ASKWorkWikiStatus: Codable, Equatable, Sendable {
    public var project: ASKWorkWikiProjectResolution
    public var knowledge: ASKWorkWikiKnowledgeStatus
    public var capabilities: [ASKWorkWikiCapability]

    public init(project: ASKWorkWikiProjectResolution, knowledge: ASKWorkWikiKnowledgeStatus, capabilities: [ASKWorkWikiCapability]) {
        self.project = project
        self.knowledge = knowledge
        self.capabilities = capabilities
    }
}
