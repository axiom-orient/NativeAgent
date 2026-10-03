import Foundation

public enum SourceLocationSpace: String, Codable, CaseIterable, Sendable {
    case page
    case line
}

public struct SourceRange: Codable, Hashable, Sendable {
    public let space: SourceLocationSpace
    public let start: Int
    public let end: Int

    public init(space: SourceLocationSpace, start: Int, end: Int) throws {
        guard start > 0, end >= start, end < Int.max else {
            throw ASKPageIndexError.invalidSourceRange(start: start, end: end)
        }
        self.space = space
        self.start = start
        self.end = end
    }

    public var count: Int {
        end - start + 1
    }

    public func contains(_ value: Int) -> Bool {
        start ... end ~= value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let space = try container.decode(SourceLocationSpace.self, forKey: .space)
        let start = try container.decode(Int.self, forKey: .start)
        let end = try container.decode(Int.self, forKey: .end)
        try self.init(space: space, start: start, end: end)
    }

    private enum CodingKeys: String, CodingKey {
        case space
        case start
        case end
    }
}

public struct SourceID: Codable, Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ value: String) {
        self.rawValue = value
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static func fromChecksum(_ checksum: String) -> SourceID {
        SourceID("src_\(checksum)")
    }
}

public struct SourceVersion: Codable, Hashable, Sendable {
    public let checksum: String
    public let contentLength: Int
    public let modifiedAt: Date?

    public init(checksum: String, contentLength: Int, modifiedAt: Date?) {
        self.checksum = checksum
        self.contentLength = contentLength
        self.modifiedAt = modifiedAt
    }
}

public struct SourceExcerpt: Codable, Hashable, Sendable {
    public let index: Int
    public let content: String

    public init(index: Int, content: String) {
        self.index = index
        self.content = content
    }
}

public struct SourceIndexNode: Codable, Hashable, Sendable {
    public let nodeID: String
    public let title: String
    public let range: SourceRange
    public let summary: String?
    public let snippet: String?
    public let children: [SourceIndexNode]

    public init(nodeID: String, title: String, range: SourceRange, summary: String? = nil, snippet: String? = nil, children: [SourceIndexNode] = []) {
        self.nodeID = nodeID
        self.title = title
        self.range = range
        self.summary = summary
        self.snippet = snippet
        self.children = children
    }
}

public struct SourceIndexDocument: Codable, Hashable, Sendable {
    public let sourceID: SourceID
    public let type: DocumentType
    public let title: String
    public let description: String?
    public let coordinateSpace: SourceLocationSpace
    public let extentCount: Int
    public let rootNodes: [SourceIndexNode]

    public init(sourceID: SourceID, type: DocumentType, title: String, description: String? = nil, coordinateSpace: SourceLocationSpace, extentCount: Int, rootNodes: [SourceIndexNode]) {
        self.sourceID = sourceID
        self.type = type
        self.title = title
        self.description = description
        self.coordinateSpace = coordinateSpace
        self.extentCount = extentCount
        self.rootNodes = rootNodes
    }
}

/// The provenance quality of the text represented by an artifact. Retrieval
/// must block when the source has no trustworthy text extraction rather than
/// treating an empty or unknown artifact as searchable evidence.
public enum SourceExtractionQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case digitalText
    case ocrRequired
    case ocrApplied
    case layoutUncertain
    case unsupported

    var blocksEvidenceRetrieval: Bool {
        self == .ocrRequired || self == .unsupported
    }
}

public struct SourceIndexArtifact: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let document: SourceIndexDocument
    public let excerpts: [SourceExcerpt]
    public let version: SourceVersion
    public let sourcePath: String?
    public let frontmatter: ASKEvidenceFrontmatter?
    public let evidenceMetadata: ASKEvidenceMetadata?
    public let extractionQuality: SourceExtractionQuality

    public init(
        schemaVersion: Int = SourceIndexArtifact.currentSchemaVersion,
        document: SourceIndexDocument,
        excerpts: [SourceExcerpt],
        version: SourceVersion,
        sourcePath: String? = nil,
        frontmatter: ASKEvidenceFrontmatter? = nil,
        evidenceMetadata: ASKEvidenceMetadata? = nil,
        extractionQuality: SourceExtractionQuality = .unsupported
    ) {
        self.schemaVersion = schemaVersion
        self.document = document
        self.excerpts = excerpts
        self.version = version
        self.sourcePath = sourcePath
        self.frontmatter = frontmatter
        self.evidenceMetadata = evidenceMetadata
        self.extractionQuality = extractionQuality
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case document
        case excerpts
        case version
        case sourcePath
        case frontmatter
        case evidenceMetadata
        case extractionQuality
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                debugDescription: "unsupported source index schema; expected \(Self.currentSchemaVersion)")
        }
        document = try container.decode(SourceIndexDocument.self, forKey: .document)
        excerpts = try container.decode([SourceExcerpt].self, forKey: .excerpts)
        version = try container.decode(SourceVersion.self, forKey: .version)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        frontmatter = try container.decodeIfPresent(ASKEvidenceFrontmatter.self, forKey: .frontmatter)
        evidenceMetadata = try container.decodeIfPresent(ASKEvidenceMetadata.self, forKey: .evidenceMetadata)
        extractionQuality = try container.decode(SourceExtractionQuality.self, forKey: .extractionQuality)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(document, forKey: .document)
        try container.encode(excerpts, forKey: .excerpts)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(sourcePath, forKey: .sourcePath)
        try container.encodeIfPresent(frontmatter, forKey: .frontmatter)
        try container.encodeIfPresent(evidenceMetadata, forKey: .evidenceMetadata)
        try container.encode(extractionQuality, forKey: .extractionQuality)
    }
}

/// Validates decoded or host-supplied artifacts before retrieval or persistence
/// turns their identifiers into dictionary keys or their ranges into offsets.
/// Public value initializers preserve their existing throwing validation
/// contract; all effectful consumers call this boundary validator and fail
/// closed instead of trapping on malformed input.
enum SourceIndexArtifactValidator {
    static func validate(_ artifact: SourceIndexArtifact) throws {
        guard artifact.schemaVersion == SourceIndexArtifact.currentSchemaVersion else {
            throw ASKPageIndexError.invalidArguments("unsupported source index schema; expected \(SourceIndexArtifact.currentSchemaVersion)")
        }
        let document = artifact.document
        guard !document.sourceID.rawValue.isEmpty else {
            throw ASKPageIndexError.invalidArguments("source index source ID must not be empty")
        }
        guard document.extentCount >= 0, document.extentCount < Int.max else {
            throw ASKPageIndexError.invalidArguments(
                "source index extent must be finite and non-negative")
        }

        var nodeIDs: Set<String> = []
        try validate(
            nodes: document.rootNodes,
            coordinateSpace: document.coordinateSpace,
            extentCount: document.extentCount,
            nodeIDs: &nodeIDs,
            sourceID: document.sourceID
        )

        for excerpt in artifact.excerpts {
            guard excerpt.index > 0, excerpt.index <= document.extentCount else {
                throw ASKPageIndexError.invalidArguments(
                    "source index excerpt is outside the document extent for \(document.sourceID.rawValue)")
            }
        }
    }

    private static func validate(
        nodes: [SourceIndexNode],
        coordinateSpace: SourceLocationSpace,
        extentCount: Int,
        nodeIDs: inout Set<String>,
        sourceID: SourceID
    ) throws {
        var pending = nodes
        while let node = pending.popLast() {
            guard !node.nodeID.isEmpty, nodeIDs.insert(node.nodeID).inserted else {
                throw ASKPageIndexError.invalidArguments(
                    "source index contains duplicate or empty node ID in \(sourceID.rawValue)")
            }
            guard node.range.space == coordinateSpace,
                  node.range.start <= extentCount,
                  node.range.end <= extentCount
            else {
                throw ASKPageIndexError.invalidArguments(
                    "source index node range is outside the document extent for \(sourceID.rawValue)")
            }
            pending.append(contentsOf: node.children)
        }
    }
}

public struct SourceAnchor: Codable, Hashable, Sendable {
    public let sourceID: SourceID
    /// Checksum of the exact source version from which this anchor was made.
    public let sourceVersionChecksum: String
    public let nodeID: String
    public let sectionPath: [String]
    public let range: SourceRange
    public let snippet: String

    public init(
        sourceID: SourceID,
        sourceVersionChecksum: String,
        nodeID: String,
        sectionPath: [String],
        range: SourceRange,
        snippet: String
    ) {
        self.sourceID = sourceID
        self.sourceVersionChecksum = sourceVersionChecksum
        self.nodeID = nodeID
        self.sectionPath = sectionPath
        self.range = range
        self.snippet = snippet
    }
}


public struct SourceCatalogEntry: Codable, Hashable, Sendable {
    public let sourceID: SourceID
    public let nodeID: String
    public let title: String
    public let sectionPath: [String]
    public let range: SourceRange
    public let summary: String?
    public let snippet: String?

    public init(sourceID: SourceID, nodeID: String, title: String, sectionPath: [String], range: SourceRange, summary: String? = nil, snippet: String? = nil) {
        self.sourceID = sourceID
        self.nodeID = nodeID
        self.title = title
        self.sectionPath = sectionPath
        self.range = range
        self.summary = summary
        self.snippet = snippet
    }
}

public struct ResolvedSourceAnchor: Codable, Hashable, Sendable {
    public let anchor: SourceAnchor
    public let documentTitle: String
    public let excerpts: [SourceExcerpt]

    public init(anchor: SourceAnchor, documentTitle: String, excerpts: [SourceExcerpt]) {
        self.anchor = anchor
        self.documentTitle = documentTitle
        self.excerpts = excerpts
    }
}

public struct KnowledgeBacklink: Codable, Hashable, Sendable {
    public let knowledgeID: String
    public let anchors: [SourceAnchor]

    public init(knowledgeID: String, anchors: [SourceAnchor]) {
        self.knowledgeID = knowledgeID
        self.anchors = anchors
    }
}


public struct BacklinkAuditReport: Codable, Hashable, Sendable {
    public let knowledgeID: String
    public let resolved: [ResolvedSourceAnchor]
    public let unresolved: [SourceAnchor]

    public init(knowledgeID: String, resolved: [ResolvedSourceAnchor], unresolved: [SourceAnchor]) {
        self.knowledgeID = knowledgeID
        self.resolved = resolved
        self.unresolved = unresolved
    }
}

public struct SourceIndexManifestEntry: Codable, Hashable, Sendable {
    public let sourceID: SourceID
    public let artifactFileName: String
    public let type: DocumentType
    public let title: String
    public let version: SourceVersion
    public let sourcePath: String?
    /// Logical indexing root, stable across owned snapshot generations.
    public let sourceRootIdentity: String?

    public init(sourceID: SourceID, artifactFileName: String, type: DocumentType, title: String, version: SourceVersion, sourcePath: String? = nil, sourceRootIdentity: String? = nil) {
        self.sourceID = sourceID
        self.artifactFileName = artifactFileName
        self.type = type
        self.title = title
        self.version = version
        self.sourcePath = sourcePath
        self.sourceRootIdentity = sourceRootIdentity
    }
}
