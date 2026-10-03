import Foundation
import KnowledgeCore

extension ASKRuntime {
    public func upsertRepresentation(_ record: RepresentationRecord) throws {
        let vault = Vault(root: root)
        try vault.bootstrap()
        try vault.writeRepresentation(record)
    }

    public func representation(sourceID: String, kind: RepresentationKind) throws -> RepresentationRecord? {
        let vault = Vault(root: root)
        try vault.bootstrap()
        return try vault.loadRepresentation(sourceID: sourceID, kind: kind)
    }

    public func listRepresentations(sourceID: String) throws -> [RepresentationRecord] {
        let vault = Vault(root: root)
        try vault.bootstrap()
        return try vault.listRepresentations(sourceID: sourceID)
    }

    public func lintRepresentations(_ request: RepresentationTrailRequest) throws -> RepresentationLintReport {
        try request.validate()
        let records = try listRepresentations(sourceID: request.sourceID)
        var byKind: [RepresentationKind: RepresentationRecord] = [:]
        for record in records { byKind[record.kind] = record }
        let availableKinds = byKind.keys.sorted { $0.rawValue < $1.rawValue }
        var findings: [RepresentationLintFinding] = []
        for requiredKind in request.requiredKinds {
            guard let record = byKind[requiredKind] else {
                findings.append(
                    RepresentationLintFinding(
                        kind: "missing_representation",
                        severity: "high",
                        item: requiredKind.rawValue,
                        summary: "Required representation is missing for source \(request.sourceID)."
                    )
                )
                continue
            }
            if record.sourceContentHash != request.sourceContentHash {
                findings.append(
                    RepresentationLintFinding(
                        kind: "stale_representation",
                        severity: "high",
                        item: requiredKind.rawValue,
                        summary: "Representation \(requiredKind.rawValue) was generated from a different source_content_hash."
                    )
                )
            }
        }

        return RepresentationLintReport(
            sourceID: request.sourceID,
            availableKinds: availableKinds,
            findings: findings
        )
    }
}
