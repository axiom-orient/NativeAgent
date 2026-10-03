import Foundation
import KnowledgeCore

struct CanonicalProjectionInfo {
    let seed: WikiProjectionSeed
    let slug: String
    let title: String
}

func orderedSourceFragments(for sourceID: String, store: KnowledgeStore) -> [SourceFragment] {
    store.sourceFragments.values
        .filter { $0.sourceID == sourceID }
        .sorted {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            return $0.fragmentID < $1.fragmentID
        }
}

func makePromotedSourceProjectionWrite(
    store: KnowledgeStore,
    source: SourceReceipt,
    slug: String,
    title: String,
    requestedAt: String,
    bodySeed: String?,
    relatedPages: [(slug: String, title: String)] = []
) -> ProjectionWrite {
    let sourceID = source.sourceID
    let fragments = orderedSourceFragments(for: sourceID, store: store)

    let metadata = ProjectionMetadata(
        projectionKind: .sourceSummary,
        projectionSpace: .wiki,
        subjectKind: "source",
        subjectID: sourceID,
        authorityIDs: [],
        sourceIDs: [sourceID],
        claimIDs: store.claims.values
            .filter { $0.subjectKind == "source" && $0.subjectID == sourceID }
            .map(\.claimID)
            .sorted(),
        historical: false,
        approvalRequired: false
    )
    let body = renderPromotedSourceBody(
        title: title,
        source: source,
        fragments: fragments,
        bodySeed: bodySeed,
        relatedPages: relatedPages
    )
    var document = ProjectionDocument(
        version: projectionDocumentVersion,
        slug: slug,
        title: title,
        bodyMD: body,
        metadata: metadata,
        generatedFromHash: "",
        generatedAt: requestedAt
    )
    document.generatedFromHash = projectionDocumentHash(document)
    return ProjectionWrite(slug: slug, state: .accepted, document: document)
}

func buildProjectionSetCompanionInfo(sourceID: String, seeds: [WikiProjectionSeed]) throws -> [CanonicalProjectionInfo] {
    var seen = Set<String>()
    var output: [CanonicalProjectionInfo] = []
    for seed in seeds {
        let metadata = ProjectionMetadata(
            projectionKind: seed.projectionKind,
            projectionSpace: .wiki,
            subjectKind: seed.subjectKind,
            subjectID: seed.subjectID,
            authorityIDs: seed.authorityIDs,
            sourceIDs: [sourceID],
            claimIDs: seed.claimIDs,
            historical: false,
            approvalRequired: false
        )
        let canonicalSlug = canonicalProjectionSlug(slug: seed.slug, metadata: metadata)
        guard seen.insert(canonicalSlug).inserted else {
            throw ASKError.validation("duplicate projection seed slug `\(canonicalSlug)`")
        }
        output.append(
            CanonicalProjectionInfo(
                seed: seed,
                slug: canonicalSlug,
                title: seed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? slugTitle(canonicalSlug) : seed.title
            )
        )
    }
    return output
}

func makeCompiledProjectionWrite(
    store: KnowledgeStore,
    source: SourceReceipt,
    sourceSlug: String,
    sourceTitle: String,
    requestedAt: String,
    seed: WikiProjectionSeed,
    canonicalSlug: String,
    relatedPages: [(slug: String, title: String)]
) -> ProjectionWrite {
    let sourceID = source.sourceID
    let fragments = orderedSourceFragments(for: sourceID, store: store)

    let claimIDs = Array(
        Set(
            seed.claimIDs
                + store.claims.values
                    .filter { $0.subjectKind == "source" && $0.subjectID == sourceID }
                    .map(\.claimID)
        )
    ).sorted()
    let metadata = ProjectionMetadata(
        projectionKind: seed.projectionKind,
        projectionSpace: .wiki,
        subjectKind: seed.subjectKind,
        subjectID: seed.subjectID,
        authorityIDs: seed.authorityIDs,
        sourceIDs: [sourceID],
        claimIDs: claimIDs,
        historical: false,
        approvalRequired: false
    )
    let title = seed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? slugTitle(canonicalSlug) : seed.title
    let body = renderCompiledProjectionBody(
        title: title,
        projectionKind: seed.projectionKind,
        source: source,
        sourceSlug: sourceSlug,
        sourceTitle: sourceTitle,
        fragments: fragments,
        bodySeed: seed.bodySeed,
        relatedPages: relatedPages
    )
    var document = ProjectionDocument(
        version: projectionDocumentVersion,
        slug: canonicalSlug,
        title: title,
        bodyMD: body,
        metadata: metadata,
        generatedFromHash: "",
        generatedAt: requestedAt
    )
    document.generatedFromHash = projectionDocumentHash(document)
    return ProjectionWrite(slug: canonicalSlug, state: .accepted, document: document)
}

func makeProjectionRemovalPlan(
    latest: ProjectionWrite,
    slug: String,
    requestedAt: String,
    trigger: String
) -> KnowledgePatchPlan {
    var superseded = latest
    superseded.state = .superseded
    superseded.document.generatedAt = requestedAt
    superseded.document.generatedFromHash = projectionDocumentHash(superseded.document)

    let patchID = stableID(prefix: "patch_projection_remove", parts: [slug, requestedAt, trigger])
    return KnowledgePatchPlan(
        version: knowledgePatchPlanVersion,
        patchID: patchID,
        patchKind: .projectionRefresh,
        generatedAt: requestedAt,
        sourceReceipts: [],
        sourceFragments: [],
        authorityRecords: [],
        projectionInvalidations: [],
        projectionWrites: [superseded],
        claims: [],
        evidence: [],
        claimEvidence: [],
        reviewItems: [],
        warnings: [],
        verification: VerificationReport(
            patchID: patchID,
            riskLevel: .low,
            disposition: .autoPublish,
            reasons: ["projection_removal"],
            requiresHumanApproval: false
        ),
        operations: [
            OperationLogEntry(
                logID: stableID(prefix: "log", parts: [patchID, "projection_remove"]),
                occurredAt: requestedAt,
                opKind: "projection_remove",
                summary: "projection removal triggered by \(trigger) for \(slug)"
            )
        ]
    )
}

func makeImportedCollectedRequest(
    imported: ASKImportedCapture,
    domain: String,
    requestedAt: String,
    focusPrompt: String?
) throws -> IngestEvidenceRequest {
    let collected = try CanonicalJSON.load(CollectedSource.self, from: URL(fileURLWithPath: imported.collectedPath))
    return try toIngestEvidenceRequest(
        collected,
        domain: domain,
        requestedAt: requestedAt,
        focusPrompt: focusPrompt
    )
}

func renderPromotedSourceBody(
    title: String,
    source: SourceReceipt,
    fragments: [SourceFragment],
    bodySeed: String?,
    relatedPages: [(slug: String, title: String)]
) -> String {
    var lines: [String] = ["# \(title)", ""]
    if let bodySeed, !bodySeed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lines.append(bodySeed.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
    }
    if !relatedPages.isEmpty {
        lines.append("## related")
        for page in relatedPages.sorted(by: { $0.slug < $1.slug }) {
            lines.append("- \(wikiLink(page.slug, title: page.title))")
        }
        lines.append("")
    }
    lines.append("## source")
    lines.append("- source_id: \(source.sourceID)")
    if let finalURL = source.metadata["final_url"], !finalURL.isEmpty {
        lines.append("- url: \(finalURL)")
    } else if let canonicalURL = source.metadata["canonical_url"], !canonicalURL.isEmpty {
        lines.append("- url: \(canonicalURL)")
    }
    lines.append("- connector: \(source.connector)")
    lines.append("- observed_at: \(source.observedAt)")
    if let description = source.metadata["description"], !description.isEmpty {
        lines.append("- description: \(description)")
    }
    lines.append("")
    lines.append("## extracted")
    let excerptBlocks = fragments.prefix(5).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if excerptBlocks.isEmpty, let noteExcerpt = source.metadata["curated_note_excerpt"], !noteExcerpt.isEmpty {
        lines.append(noteExcerpt)
    } else {
        lines.append(contentsOf: excerptBlocks)
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

func renderCompiledProjectionBody(
    title: String,
    projectionKind: ProjectionKind,
    source: SourceReceipt,
    sourceSlug: String,
    sourceTitle: String,
    fragments: [SourceFragment],
    bodySeed: String?,
    relatedPages: [(slug: String, title: String)]
) -> String {
    var lines: [String] = ["# \(title)", ""]
    if let bodySeed, !bodySeed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lines.append(bodySeed.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
    }
    lines.append("## grounding")
    lines.append("- source: \(wikiLink(sourceSlug, title: sourceTitle))")
    lines.append("- source_id: \(source.sourceID)")
    lines.append("- projection_kind: \(projectionKind.rawValue)")
    lines.append("- observed_at: \(source.observedAt)")
    lines.append("")
    if !relatedPages.isEmpty {
        lines.append("## related")
        for page in relatedPages.sorted(by: { $0.slug < $1.slug }) {
            lines.append("- \(wikiLink(page.slug, title: page.title))")
        }
        lines.append("")
    }
    lines.append("## evidence")
    let excerptBlocks = fragments.prefix(4).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if excerptBlocks.isEmpty, let noteExcerpt = source.metadata["curated_note_excerpt"], !noteExcerpt.isEmpty {
        lines.append(noteExcerpt)
    } else {
        lines.append(contentsOf: excerptBlocks)
    }
    lines.append("")
    return lines.joined(separator: "\n")
}
