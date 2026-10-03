import Foundation
import KnowledgeCore
import KnowledgeRuntime

struct ASKWorkWikiCaptureWorkflow: Sendable {
  let maintainer: any ASKKnowledgeMaintainer

  func importAndPlan(
    _ request: ASKWorkWikiCaptureRequest
  ) async throws -> ASKWorkWikiCapturePlan {
    try ASKWorkWikiEvidenceCapture.validate(request)
    try maintainer.ensureKnowledgeBase()

    let imported = try maintainer.importCollected(request.captureManifestPath)
    let collectedData = try Data(contentsOf: URL(fileURLWithPath: imported.collectedPath))
    let collected = try CanonicalJSON.decode(CollectedSource.self, from: collectedData)
    let ingestRequest = try toIngestEvidenceRequest(
      collected,
      domain: request.domain,
      requestedAt: request.requestedAt,
      focusPrompt: request.focusPrompt
    )
    let outcome = try maintainer.planEvidenceIngest(ingestRequest)
    return ASKWorkWikiCapturePlan(
      importedCapture: imported,
      ingestRequest: ingestRequest,
      patch: outcome.patch
    )
  }

  func capture(_ request: ASKWorkWikiCaptureRequest) async throws -> ASKWorkWikiCapturePlan {
    let plan = try await importAndPlan(request)
    try maintainer.stage(plan.patch)
    return plan
  }
}
