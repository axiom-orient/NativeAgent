import EvidenceIndex
import PageIndex
import Foundation
import KnowledgeCore
import KnowledgeRuntime

struct ASKWorkWikiReportWorkflow: Sendable {
  let maintainer: any ASKKnowledgeMaintainer
  let evidenceIndex: ASKEvidenceIndex

  func plan(_ request: ASKWorkWikiReportRequest) async throws -> ASKWorkWikiReportPlan {
    try ASKWorkWikiReportProjection.validate(request)

    let evidenceQuery = ASKEvidenceQuery(
      text: request.queryText,
      filter: request.filter,
      limit: 20,
      excerptLineLimit: 12
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
        "failed to build report evidence pack",
        context: ["cause": String(describing: error)]
      )
    }
    guard !pack.hits.isEmpty else {
      throw await ASKWorkWikiEvidenceDiagnosis.emptyPackError(
        operation: "report",
        query: evidenceQuery,
        request: (request.maxEvidenceBytes, request.includeStaleEvidence),
        evidenceIndex: evidenceIndex
      )
    }

    let provisionalSlug = ASKWorkWikiReportProjection.projectionSlug(for: request)
    let expectedBaseRevision = try maintainer.projectionDocument(slug: provisionalSlug)?.generatedFromHash
    let write = try ASKWorkWikiReportProjection.makeProjectionWrite(
      request: request,
      evidencePack: pack,
      expectedBaseRevision: expectedBaseRevision
    )
    let outcome = try maintainer.planProjectionRefresh(
      RefreshProjectionRequest(
        version: refreshProjectionRequestVersion,
        requestedAt: request.requestedAt,
        trigger: "workwiki_report",
        proposedWrites: [write]
      )
    )
    return ASKWorkWikiReportPlan(
      evidencePack: pack,
      projectionWrite: write,
      patch: outcome.patch
    )
  }

  func stage(_ request: ASKWorkWikiReportRequest) async throws -> ASKWorkWikiReportPlan {
    let plan = try await plan(request)
    try maintainer.ensureKnowledgeBase()
    try maintainer.stage(plan.patch)
    return plan
  }

  func approve(
    _ request: ASKWorkWikiReportApprovalRequest
  ) async throws -> ASKWorkWikiReportApprovalResult {
    try ASKWorkWikiReportApproval.validate(request)
    try maintainer.ensureKnowledgeBase()

    let plan = try ASKWorkWikiReportApproval.resolvePendingWorkReportPlan(
      patchID: request.patchID,
      pendingPlans: maintainer.pendingPatchPlans()
    )
    let verification = try maintainer.verify(plan)
    guard !verification.requiresHumanChoice else {
      throw ASKWorkWikiError(
        .unsupportedPatch,
        "work-wiki report approval does not support choice-gated patches"
      )
    }

    let sourceStatuses = try await reportSourceStatuses(
      for: plan,
      requireFreshEvidence: request.requireFreshEvidence
    )
    let receipt = try ASKWorkWikiReportApproval.buildReceipt(request)
    let applySummary = try maintainer.apply(plan, receipt)
    return ASKWorkWikiReportApprovalResult(
      patch: plan,
      verification: verification,
      receipt: receipt,
      sourceStatuses: sourceStatuses,
      applySummary: applySummary
    )
  }

  func reject(
    _ request: ASKWorkWikiReportRejectionRequest
  ) async throws -> ASKWorkWikiReportRejectionResult {
    try ASKWorkWikiReportRejection.validate(request)
    try maintainer.ensureKnowledgeBase()

    let plan = try ASKWorkWikiReportRejection.resolvePendingWorkReportPlan(
      patchID: request.patchID,
      pendingPlans: maintainer.pendingPatchPlans()
    )
    let verification = try maintainer.verify(plan)
    guard !verification.requiresHumanChoice else {
      throw ASKWorkWikiError(
        .unsupportedPatch,
        "work-wiki report rejection does not support choice-gated patches"
      )
    }

    let receipt = try ASKWorkWikiReportRejection.buildReceipt(request)
    let applySummary = try maintainer.apply(plan, receipt)
    return ASKWorkWikiReportRejectionResult(
      patch: plan,
      verification: verification,
      receipt: receipt,
      applySummary: applySummary
    )
  }

  private func reportSourceStatuses(
    for plan: KnowledgePatchPlan,
    requireFreshEvidence: Bool
  ) async throws -> [ASKWorkWikiReportApprovalSourceStatus] {
    let sourceIDs = ASKWorkWikiReportApproval.sourceIDs(in: plan)
    var expectedVersions: [String: String] = [:]
    for write in plan.projectionWrites {
      for (sourceID, checksum) in write.document.metadata.sourceVersionChecksums {
        if let existing = expectedVersions[sourceID], existing != checksum {
          throw ASKWorkWikiError(.staleIndexedEvidence,
            "work-wiki report contains conflicting source revisions for \(sourceID)")
        }
        expectedVersions[sourceID] = checksum
      }
    }
    var statuses: [ASKWorkWikiReportApprovalSourceStatus] = []
    var invalid: [String] = []

    for sourceID in sourceIDs {
      let status: ASKEvidenceDocumentStatus?
      do {
        status = try await evidenceIndex.freshness(sourceID: SourceID(sourceID))
      } catch {
        throw ASKWorkWikiError(
          .freshnessCheckFailed,
          "failed to check freshness for report source",
          context: [
            "sourceID": sourceID,
            "cause": String(describing: error),
          ]
        )
      }
      guard let status else {
        invalid.append("\(sourceID):not_indexed")
        continue
      }
      statuses.append(ASKWorkWikiReportApproval.sourceStatusItem(status))
      guard let expectedChecksum = expectedVersions[sourceID] else {
        invalid.append("\(sourceID):revision_missing")
        continue
      }
      if status.storedChecksum != expectedChecksum {
        invalid.append("\(sourceID):revision_changed")
        continue
      }
      if status.freshness != .ok && status.freshness != .unknown {
        invalid.append("\(sourceID):\(status.freshness.rawValue)")
      }
    }

    let revisionInvalid = invalid.filter {
      $0.hasSuffix(":revision_missing") || $0.hasSuffix(":revision_changed") || $0.hasSuffix(":not_indexed")
    }
    if !revisionInvalid.isEmpty {
      throw ASKWorkWikiError(
        .staleIndexedEvidence,
        "work-wiki report approval source revision changed since review: \(revisionInvalid.sorted().joined(separator: ", "))"
      )
    }
    if requireFreshEvidence && !invalid.isEmpty {
      throw ASKWorkWikiError(
        .staleIndexedEvidence,
        "work-wiki report approval requires fresh indexed evidence: \(invalid.sorted().joined(separator: ", "))"
      )
    }
    return statuses.sorted { lhs, rhs in lhs.sourceID < rhs.sourceID }
  }
}
