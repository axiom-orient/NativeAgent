import Foundation
import PageIndex

/// Freshness of the borrowed original and integrity of retained indexed content
/// are distinct facts. Historical use must be explicitly selected by the caller.
public enum ASKEvidenceFreshnessRequirement: String, Codable, Sendable {
    case currentSource
    case retainedIndexedContent
}

/// Immutable address of indexed content. Rendering/truncation never changes it.
public struct ASKEvidenceReference: Codable, Equatable, Sendable {
    public let sourceID: SourceID
    public let sourceVersionChecksum: String
    public let nodeID: String
    public let range: SourceRange
    public let contentSHA256: String

    public init(sourceID: SourceID, sourceVersionChecksum: String, nodeID: String,
                range: SourceRange, contentSHA256: String) throws {
        guard !sourceID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceVersionChecksum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              contentSHA256.utf8.count == 64,
              contentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ASKPageIndexError.invalidArguments("Invalid exact evidence reference")
        }
        self.sourceID = sourceID
        self.sourceVersionChecksum = sourceVersionChecksum
        self.nodeID = nodeID
        self.range = range
        self.contentSHA256 = contentSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, sourceVersionChecksum, nodeID, range, contentSHA256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceID: values.decode(SourceID.self, forKey: .sourceID),
            sourceVersionChecksum: values.decode(String.self, forKey: .sourceVersionChecksum),
            nodeID: values.decode(String.self, forKey: .nodeID),
            range: values.decode(SourceRange.self, forKey: .range),
            contentSHA256: values.decode(String.self, forKey: .contentSHA256)
        )
    }
}

public enum ASKEvidenceUnavailableReason: String, Codable, Sendable {
    case versionMissing
    case extractionUnavailable
    case rangeUnavailable
    case digestMismatch
    case sourceStale
    case sourceMissing
    case sourceUnknown
}

/// Verified retained representation, not proof that ASK owns the original file.
/// Decoded data must be resolved again before it is used as current evidence.
public struct ASKEvidenceContent: Codable, Equatable, Sendable {
    public let reference: ASKEvidenceReference
    public let excerpts: [SourceExcerpt]
    public let sourceFreshness: ASKEvidenceFreshnessStatus
}

public enum ASKEvidenceResolution: Codable, Equatable, Sendable {
    case available(ASKEvidenceContent)
    case unavailable(ASKEvidenceUnavailableReason)
}

public struct ASKEvidenceGroundedHit: Codable, Equatable, Sendable {
    /// Convenience view; the exact reference is authoritative.
    public let hit: ASKEvidenceHit
    public let reference: ASKEvidenceReference
}

public struct ASKEvidenceRejection: Codable, Equatable, Sendable {
    public let sourceID: SourceID
    public let nodeID: String
    public let sourceVersionChecksum: String?
    public let reason: ASKEvidenceUnavailableReason
}

public struct ASKEvidenceGroundedPack: Codable, Equatable, Sendable {
    public let queryText: String
    public let evidence: [ASKEvidenceGroundedHit]
    public let rejected: [ASKEvidenceRejection]
    /// Byte budget applies to this presentation, not to exact reference identity.
    public let renderedMarkdown: String
    public let maxBytes: Int
    public let truncated: Bool
}

/// Pure validation and hashing of existing PageIndex data; no second store.
enum ASKEvidenceGrounding {
    static func excerpts(nodeID: String, range: SourceRange,
                         in artifact: SourceIndexArtifact) -> [SourceExcerpt]? {
        guard let node = SourceIndexNavigator.node(forID: nodeID, in: artifact.document.rootNodes),
              node.range == range, artifact.document.coordinateSpace == range.space else { return nil }
        let excerpts = artifact.excerpts.filter { range.contains($0.index) }.sorted { $0.index < $1.index }
        guard excerpts.count == range.count,
              excerpts.enumerated().allSatisfy({ $0.element.index == range.start + $0.offset }) else { return nil }
        return excerpts
    }

    /// Stable UTF-8 length-prefixed encoding; indices and empty lines participate.
    static func digest(_ excerpts: [SourceExcerpt]) -> String {
        var canonical = "ask-indexed-excerpts/1\n"
        for excerpt in excerpts {
            canonical += "\(excerpt.index):\(excerpt.content.utf8.count):\(excerpt.content)"
        }
        return StableDigest.sha256Hex(Data(canonical.utf8))
    }

    static func rejection(for freshness: ASKEvidenceFreshnessStatus,
                          requirement: ASKEvidenceFreshnessRequirement) -> ASKEvidenceUnavailableReason? {
        guard requirement == .currentSource else { return nil }
        switch freshness {
        case .ok: return nil
        case .stale: return .sourceStale
        case .missing: return .sourceMissing
        case .unknown: return .sourceUnknown
        }
    }
}
