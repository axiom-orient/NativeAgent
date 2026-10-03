import EvidenceIndex
import PageIndex
import Foundation
import KnowledgeRuntime

/// Public concurrency boundary for work-wiki workflows.
public actor ASKWorkWikiRuntime {
  private let captureWorkflow: ASKWorkWikiCaptureWorkflow
  private let reportWorkflow: ASKWorkWikiReportWorkflow
  private let closeDayWorkflow: ASKWorkWikiCloseDayWorkflow
  private let doctorWorkflow: ASKWorkWikiDoctorWorkflow
  private var mutationState: ASKWorkWikiMutationState = .idle

  public init(
    maintainer: any ASKKnowledgeMaintainer,
    evidenceIndex: ASKEvidenceIndex,
    storageHealthRuntime: ASKStorageHealthRuntime? = nil
  ) {
    self.captureWorkflow = ASKWorkWikiCaptureWorkflow(maintainer: maintainer)
    self.reportWorkflow = ASKWorkWikiReportWorkflow(
      maintainer: maintainer,
      evidenceIndex: evidenceIndex
    )
    self.closeDayWorkflow = ASKWorkWikiCloseDayWorkflow(
      maintainer: maintainer,
      evidenceIndex: evidenceIndex
    )
    self.doctorWorkflow = ASKWorkWikiDoctorWorkflow(
      maintainer: maintainer,
      evidenceIndex: evidenceIndex,
      storageHealthRuntime: storageHealthRuntime
    )
  }

  /// Imports capture artifacts before planning. This is intentionally treated as a mutation.
  public func importAndPlanEvidenceCapture(
    _ request: ASKWorkWikiCaptureRequest
  ) async throws -> ASKWorkWikiCapturePlan {
    try begin(.importCapture)
    defer { finish(.importCapture) }
    return try await captureWorkflow.importAndPlan(request)
  }

  @discardableResult
  public func captureEvidence(
    _ request: ASKWorkWikiCaptureRequest
  ) async throws -> ASKWorkWikiCapturePlan {
    try begin(.captureEvidence)
    defer { finish(.captureEvidence) }
    return try await captureWorkflow.capture(request)
  }

  public func planReport(
    _ request: ASKWorkWikiReportRequest
  ) async throws -> ASKWorkWikiReportPlan {
    try await reportWorkflow.plan(request)
  }

  @discardableResult
  public func stageReport(
    _ request: ASKWorkWikiReportRequest
  ) async throws -> ASKWorkWikiReportPlan {
    try begin(.stageReport)
    defer { finish(.stageReport) }
    return try await reportWorkflow.stage(request)
  }

  public func approveReport(
    _ request: ASKWorkWikiReportApprovalRequest
  ) async throws -> ASKWorkWikiReportApprovalResult {
    try begin(.approveReport)
    defer { finish(.approveReport) }
    return try await reportWorkflow.approve(request)
  }

  public func rejectReport(
    _ request: ASKWorkWikiReportRejectionRequest
  ) async throws -> ASKWorkWikiReportRejectionResult {
    try begin(.rejectReport)
    defer { finish(.rejectReport) }
    return try await reportWorkflow.reject(request)
  }

  public func planCloseDay(
    _ request: ASKWorkWikiCloseDayRequest
  ) async throws -> ASKWorkWikiCloseDayPlan {
    try await closeDayWorkflow.plan(request)
  }

  @discardableResult
  public func closeDay(
    _ request: ASKWorkWikiCloseDayRequest
  ) async throws -> ASKWorkWikiCloseDayPlan {
    try begin(.closeDay)
    defer { finish(.closeDay) }
    return try await closeDayWorkflow.close(request)
  }

  public func doctor(
    _ request: ASKWorkWikiDoctorRequest = ASKWorkWikiDoctorRequest()
  ) async throws -> ASKWorkWikiDoctorReport {
    try await doctorWorkflow.run(request)
  }

  private func begin(_ operation: ASKWorkWikiMutationOperation) throws {
    switch ASKWorkWikiMutationReducer.reduce(
      state: mutationState,
      event: .begin(operation)
    ) {
    case .accepted(let next):
      mutationState = next
    case .conflict(let active, let requested):
      throw ASKWorkWikiError(
        .invalidRequest,
        "work-wiki mutation is already in progress",
        context: [
          "active": active.rawValue,
          "requested": requested.rawValue,
        ]
      )
    }
  }

  private func finish(_ operation: ASKWorkWikiMutationOperation) {
    mutationState = ASKWorkWikiMutationReducer.finishing(
      state: mutationState,
      operation: operation
    )
  }
}
