import EvidenceIndex
import PageIndex
import Foundation
import KnowledgeRuntime

struct ASKWorkWikiCloseDayWorkflow: Sendable {
  let maintainer: any ASKKnowledgeMaintainer
  let evidenceIndex: ASKEvidenceIndex

  func plan(_ request: ASKWorkWikiCloseDayRequest) async throws -> ASKWorkWikiCloseDayPlan {
    try ASKWorkWikiCloseDay.validate(request)

    let documents: [ASKEvidenceMetadata]
    do {
      documents = try await evidenceIndex.listDocuments(filter: request.filter)
    } catch {
      throw ASKWorkWikiError(
        .sourceIndexFailed,
        "failed to list indexed day documents",
        context: ["cause": String(describing: error)]
      )
    }
    let dayDocuments = ASKWorkWikiCloseDay.dayDocuments(from: documents, matching: request)
    guard !dayDocuments.isEmpty else {
      throw ASKWorkWikiError(
        .noFreshEvidence,
        "work-wiki close-day requires at least one matching day document"
      )
    }

    let evidenceQuery = ASKWorkWikiCloseDay.evidenceQuery(
      for: request,
      documents: dayDocuments
    )
    let pack: ASKEvidencePack
    do {
      pack = try await evidenceIndex.buildPack(
        ASKEvidencePackRequest(
          query: evidenceQuery,
          maxBytes: request.maxEvidenceBytes,
          includeStale: request.includeStaleEvidence
        )
      )
    } catch {
      throw ASKWorkWikiError(
        .sourceIndexFailed,
        "failed to build close-day evidence pack",
        context: ["cause": String(describing: error)]
      )
    }
    guard !pack.hits.isEmpty else {
      throw await ASKWorkWikiEvidenceDiagnosis.emptyPackError(
        operation: "close-day",
        query: evidenceQuery,
        request: (request.maxEvidenceBytes, request.includeStaleEvidence),
        evidenceIndex: evidenceIndex
      )
    }

    let summary = ASKWorkWikiCloseDay.summarize(pack)
    let slug = ASKWorkWikiCloseDay.projectionSlug(for: request)
    let baseRevision = try maintainer.projectionDocument(slug: slug)?.generatedFromHash
    let write = try ASKWorkWikiCloseDay.makeProjectionWrite(
      request: request,
      evidencePack: pack,
      documents: dayDocuments,
      summary: summary,
      expectedBaseRevision: baseRevision
    )
    let outcome = try maintainer.planProjectionRefresh(
      RefreshProjectionRequest(
        version: refreshProjectionRequestVersion,
        requestedAt: request.requestedAt,
        trigger: "workwiki_close_day",
        proposedWrites: [write]
      )
    )
    return ASKWorkWikiCloseDayPlan(
      evidencePack: pack,
      summary: summary,
      projectionWrite: write,
      patch: outcome.patch
    )
  }

  func close(_ request: ASKWorkWikiCloseDayRequest) async throws -> ASKWorkWikiCloseDayPlan {
    let plan = try await plan(request)
    try maintainer.ensureKnowledgeBase()
    try maintainer.stage(plan.patch)
    return plan
  }
}
