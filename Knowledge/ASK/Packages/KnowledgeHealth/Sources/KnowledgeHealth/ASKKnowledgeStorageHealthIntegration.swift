import Foundation
import KnowledgeRuntime
import EvidenceIndex

public enum ASKKnowledgeStorageHealthError: Error, CustomStringConvertible, Sendable, Equatable {
    case unsupportedEvidenceRebuild(String)

    public var description: String {
        switch self {
        case .unsupportedEvidenceRebuild(let message): message
        }
    }
}

public enum ASKKnowledgeStorageHealthIntegration {
    public static func makeStorageHealthRuntime(
        vaultURL: URL,
        evidenceIndexURL: URL? = nil
    ) async throws -> ASKStorageHealthRuntime {
        let canonical = ASKVaultCanonicalGenerationReader(root: vaultURL)
        var derived: [any ASKDerivedGenerationReading] = [
            ASKVaultSearchGenerationReader(root: vaultURL, canonical: canonical)
        ]
        if let evidenceIndexURL {
            derived.append(
                ASKEvidenceIndexGenerationReader(
                    evidenceIndex: try await ASKEvidenceIndex.open(workspaceURL: evidenceIndexURL),
                    canonical: canonical
                )
            )
        }
        return ASKStorageHealthRuntime(canonical: canonical, derivedIndexes: derived)
    }

    public static func makeWorkWikiStorageHealthRuntime(
        vaultURL: URL,
        evidenceIndex: ASKEvidenceIndex
    ) -> ASKStorageHealthRuntime {
        let canonical = ASKVaultCanonicalGenerationReader(root: vaultURL)
        return ASKStorageHealthRuntime(
            canonical: canonical,
            derivedIndexes: [
                ASKVaultSearchGenerationReader(root: vaultURL, canonical: canonical),
                ASKEvidenceIndexGenerationReader(evidenceIndex: evidenceIndex, canonical: canonical),
            ]
        )
    }
}

public struct ASKEvidenceIndexGenerationReader: ASKDerivedGenerationReading, Sendable {
    private let evidenceIndex: ASKEvidenceIndex
    private let canonical: any ASKCanonicalGenerationReading

    public init(evidenceIndex: ASKEvidenceIndex, canonical: any ASKCanonicalGenerationReading) {
        self.evidenceIndex = evidenceIndex
        self.canonical = canonical
    }

    public var component: ASKDerivedComponent { get async { .evidence } }

    public func currentGeneration() async throws -> ASKStorageGeneration? {
        let expected = try await canonical.currentGeneration()
        let statuses = try await evidenceIndex.freshnessReport()
        guard !statuses.isEmpty else { return nil }
        let invalid = statuses.contains { $0.freshness == .stale || $0.freshness == .missing }
        return ASKStorageGeneration(
            component: .evidence,
            value: invalid ? max(0, expected.value - 1) : expected.value,
            updatedAt: expected.updatedAt
        )
    }

    public func rebuild(to canonicalGeneration: ASKStorageGeneration) async throws -> ASKStorageGeneration {
        let current = try await currentGeneration()
        guard current?.value == canonicalGeneration.value else {
            throw ASKKnowledgeStorageHealthError.unsupportedEvidenceRebuild(
                "ASKEvidenceIndex rebuild requires source-root indexing before storage repair."
            )
        }
        return ASKStorageGeneration(
            component: .evidence,
            value: canonicalGeneration.value,
            updatedAt: canonicalGeneration.updatedAt
        )
    }
}
