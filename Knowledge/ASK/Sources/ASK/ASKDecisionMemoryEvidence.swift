import EvidenceIndex
import Foundation
import KnowledgeCore
import PageIndex

extension MemoryEvidenceRef {
    /// Preserves a grounded lookup's exact coordinates. The reference is probed
    /// again at root verification, promotion, and context-query time.
    public init(evidenceID: String, reference: ASKEvidenceReference) {
        self.init(evidenceID: evidenceID, kind: .pageIndexAnchor, freshness: .fresh,
            sourceID: reference.sourceID.rawValue, nodeID: reference.nodeID,
            exactAnchor: MemoryExactSourceAnchor(
                sourceVersionChecksum: reference.sourceVersionChecksum,
                coordinateSpace: reference.range.space.rawValue,
                rangeStart: reference.range.start, rangeEnd: reference.range.end,
                contentSHA256: reference.contentSHA256))
    }
}

/// The only conversion from memory values to the existing exact-source resolver.
/// Does not infer semantic entailment, modify the journal, or substitute a version.
enum ASKDecisionMemoryEvidence {
    static func inspect(recordID: String, refs: [MemoryEvidenceRef], indexURL: URL) async throws -> [OmissionDiagnostic] {
        var omissions: [OmissionDiagnostic] = []
        var index: ASKEvidenceIndex?
        for ref in refs {
            try Task.checkCancellation()
            try ref.validate()
            let failure: (ContextOmissionReason, String)?
            if ref.freshness != .fresh {
                failure = (ref.freshness == .stale ? .staleEvidence : .unverified, "declared_" + ref.freshness.rawValue)
            } else {
                switch ref.kind {
                case .humanApproval:
                    // Explicit host judgment is not a claim of source freshness.
                    failure = nil
                case .capturedToolOutput:
                    failure = (.unverified, "receiptVerificationUnavailable")
                case .vaultEvidence:
                    failure = (.unverified, "exactAnchorMissing")
                case .pageIndexAnchor:
                    guard let anchor = ref.exactAnchor, let sourceID = ref.sourceID,
                          let nodeID = ref.nodeID,
                          let space = SourceLocationSpace(rawValue: anchor.coordinateSpace) else {
                        throw ASKError.validation("Page-index evidence requires an exact source anchor")
                    }
                    let reference = try ASKEvidenceReference(sourceID: SourceID(sourceID),
                        sourceVersionChecksum: anchor.sourceVersionChecksum, nodeID: nodeID,
                        range: SourceRange(space: space, start: anchor.rangeStart, end: anchor.rangeEnd),
                        contentSHA256: anchor.contentSHA256)
                    let resolver: ASKEvidenceIndex
                    if let index { resolver = index }
                    else {
                        resolver = try await ASKEvidenceIndex.open(workspaceURL: indexURL)
                        index = resolver
                    }
                    switch try await resolver.resolve(reference, freshnessRequirement: .currentSource) {
                    case .available: failure = nil
                    case .unavailable(let reason):
                        failure = (reason == .sourceUnknown ? .unverified : .staleEvidence, reason.rawValue)
                    }
                }
            }
            if let failure {
                omissions.append(OmissionDiagnostic(recordID: recordID, reason: failure.0,
                    evidenceID: ref.evidenceID, detail: failure.1))
            }
        }
        if refs.isEmpty {
            omissions.append(OmissionDiagnostic(recordID: recordID, reason: .unverified, detail: "evidenceMissing"))
        }
        return omissions
    }

    static func requireCurrent(recordID: String, refs: [MemoryEvidenceRef], indexURL: URL) async throws {
        if let failure = try await inspect(recordID: recordID, refs: refs, indexURL: indexURL).first {
            throw ASKDiagnostic(code: .conflict, operation: .apply,
                message: "Decision memory evidence could not be verified: \(failure.detail ?? "unknown")",
                context: ["recordID": recordID, "evidenceID": failure.evidenceID ?? "",
                          "reason": failure.detail ?? "unknown"], recovery: .correctInput)
        }
        try Task.checkCancellation()
    }
}
