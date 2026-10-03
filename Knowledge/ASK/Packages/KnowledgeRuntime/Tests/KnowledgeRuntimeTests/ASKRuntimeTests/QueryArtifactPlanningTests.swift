import Foundation
import Testing
import KnowledgeCore
import KnowledgeRuntime

private func tempDir(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sampleProjectionWrite(
    slug: String,
    title: String,
    body: String,
    kind: ProjectionKind,
    space: ProjectionSpace,
    authorityIDs: [String] = [],
    sourceIDs: [String] = ["src_bridge"],
    claimIDs: [String] = [],
    generatedAt: String = "2026-04-10T12:00:00Z"
) -> ProjectionWrite {
    let metadata = ProjectionMetadata(
        projectionKind: kind,
        projectionSpace: space,
        subjectKind: "project",
        subjectID: "swift-ios",
        authorityIDs: authorityIDs,
        sourceIDs: sourceIDs,
        claimIDs: claimIDs,
        historical: false,
        approvalRequired: space == .playbook
    )
    var document = ProjectionDocument(
        version: projectionDocumentVersion,
        slug: slug,
        title: title,
        bodyMD: body,
        metadata: metadata,
        generatedFromHash: "",
        generatedAt: generatedAt
    )
    document.generatedFromHash = projectionDocumentHash(document)
    return ProjectionWrite(slug: slug, state: .accepted, document: document)
}

@Test
func publicQueryArtifactPlannerBuildsPatchFromProjectionSlugs() throws {
    let root = try tempDir("ask-query-artifact")
    let runtime = ASKRuntime(root: root)
    _ = try runtime.ensureVault()

    let write = sampleProjectionWrite(
        slug: "current/swift-ios",
        title: "Swift iOS",
        body: "Truth stays in ASK.",
        kind: .currentSnapshot,
        space: .wiki,
        authorityIDs: ["auth_current"],
        sourceIDs: ["src_bridge"],
        claimIDs: ["claim_bridge"]
    )
    let patch = try runtime.planProjectionRefresh(
        RefreshProjectionRequest(
            version: refreshProjectionRequestVersion,
            requestedAt: "2026-04-10T12:01:00Z",
            trigger: "seed",
            proposedWrites: [write]
        )
    )
    let receipt = try runtime.buildReceipt(
        for: patch.patch,
        decision: .approved,
        decidedBy: "reviewer",
        decidedAt: "2026-04-10T12:02:00Z"
    )
    _ = try runtime.apply(patch.patch, receipt)

    let fileBack = try runtime.planQueryArtifact(
        QueryArtifactRequest(
            question: "How should ASK and AMA compose?",
            answerMarkdown: "ASK owns truth. AMA owns reasoning.",
            projectionSlugs: ["current/swift-ios"],
            fileBackSlug: "query/ask-ama-compose",
            requestedAt: "2026-04-10T12:03:00Z"
        )
    )

    #expect(fileBack.projectionWrites.first?.slug == "query/ask-ama-compose")
    #expect(fileBack.projectionWrites.first?.document.metadata.authorityIDs == ["auth_current"])
    #expect(fileBack.projectionWrites.first?.document.metadata.sourceIDs == ["src_bridge"])
    #expect(fileBack.projectionWrites.first?.document.metadata.claimIDs == ["claim_bridge"])
}
