import EvidenceIndex
import PageIndex
import Foundation
import KnowledgeRuntime

struct ASKWorkWikiDoctorWorkflow: Sendable {
  let maintainer: any ASKKnowledgeMaintainer
  let evidenceIndex: ASKEvidenceIndex
  let storageHealthRuntime: ASKStorageHealthRuntime?

  func run(
    _ request: ASKWorkWikiDoctorRequest = ASKWorkWikiDoctorRequest()
  ) async throws -> ASKWorkWikiDoctorReport {
    try maintainer.ensureKnowledgeBase()
    var findings = try await ASKWorkWikiDoctor.findings(
      request: request,
      maintainer: maintainer,
      evidenceIndex: evidenceIndex
    )
    let storageHealth = try await storageHealthRuntime?.healthReport()
    if request.checkStorageHealth, let storageHealth {
      findings.append(contentsOf: ASKWorkWikiDoctor.storageHealthFindings(storageHealth))
    }
    return ASKWorkWikiDoctorReport(
      findings: ASKWorkWikiDoctor.sortedFindings(findings),
      storageHealth: storageHealth
    )
  }
}
