import Foundation
import Testing
@testable import KnowledgeCore

struct CurrentSchemaTests {
    private func projection() -> ProjectionDocument {
        var document = ProjectionDocument(
            version: projectionDocumentVersion, slug: "notes/current", title: "Current",
            bodyMD: "Current content", metadata: ProjectionMetadata(
                projectionKind: .sourceSummary, projectionSpace: .wiki,
                subjectKind: "source", subjectID: "source", authorityIDs: [], sourceIDs: [],
                claimIDs: [], historical: false, approvalRequired: false),
            generatedFromHash: "pending", generatedAt: "2026-09-13T00:00:00Z")
        document.generatedFromHash = projectionDocumentHash(document)
        return document
    }

    @Test func projectionRequiresCurrentVersionAndExplicitProvenanceField() throws {
        let current = projection()
        try current.validate()
        #expect(try CanonicalJSON.decode(ProjectionDocument.self,
            from: CanonicalJSON.data(for: current)) == current)
        var object = try #require(CanonicalJSON.object(from: CanonicalJSON.data(for: current)) as? [String: Any])
        var metadata = try #require(object["metadata"] as? [String: Any])
        metadata.removeValue(forKey: "source_version_checksums")
        object["metadata"] = metadata
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try CanonicalJSON.decode(ProjectionDocument.self, from: bytes)
        }
        var unsupported = current
        unsupported.version = "knowledge-projection-document.v2"
        #expect(throws: ASKError.self) { try unsupported.validate() }
    }

    @Test func pageIndexMemoryRequiresExactVersionRangeAndDigest() throws {
        var reference = MemoryEvidenceRef(evidenceID: "evidence", kind: .pageIndexAnchor,
            freshness: .fresh, sourceID: "source", nodeID: "node")
        #expect(throws: ASKError.self) { try reference.validate() }
        reference.exactAnchor = MemoryExactSourceAnchor(sourceVersionChecksum: "revision",
            coordinateSpace: "line", rangeStart: 1, rangeEnd: 1,
            contentSHA256: String(repeating: "a", count: 64))
        try reference.validate()
        var record = MemoryRecord(recordID: "memory", kind: .observation,
            subject: MemorySubject(kind: "source", subjectID: "source"),
            scope: MemoryScope(workspaceID: "workspace"), statement: "Observed content",
            createdAt: "2026-09-13T00:00:00Z", evidenceRefs: [reference])
        try record.validate()
        record.version = "ask-decision-memory-record.v1"
        #expect(throws: ASKError.self) { try record.validate() }
    }

    @Test func versionedRepresentationsRejectUnsupportedVersions() throws {
        var record = RepresentationRecord(sourceID: "source", kind: .ocrText,
            sourceContentHash: "hash", generatedAt: "2026-09-13T00:00:00Z",
            generator: "test", bodyMD: "Recognized content")
        try record.validate()
        record.version = "1"
        #expect(throws: ASKError.self) { try record.validate() }
    }
}
