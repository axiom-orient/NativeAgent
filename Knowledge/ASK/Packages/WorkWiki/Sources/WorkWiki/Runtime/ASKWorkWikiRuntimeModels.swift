import Foundation
import KnowledgeRuntime
import EvidenceIndex
import PageIndex

public struct ASKWorkWikiReportRequest: Sendable, Equatable {
    public var title: String
    public var queryText: String
    public var requestedAt: String
    public var slug: String?
    public var subjectID: String?
    public var filter: ASKEvidenceFilter
    public var maxEvidenceBytes: Int
    public var includeStaleEvidence: Bool

    public init(
        title: String,
        queryText: String,
        requestedAt: String,
        slug: String? = nil,
        subjectID: String? = nil,
        filter: ASKEvidenceFilter = ASKEvidenceFilter(scopes: [.work]),
        maxEvidenceBytes: Int = 262_144,
        includeStaleEvidence: Bool = false
    ) {
        self.title = title
        self.queryText = queryText
        self.requestedAt = requestedAt
        self.slug = slug
        self.subjectID = subjectID
        self.filter = filter
        self.maxEvidenceBytes = maxEvidenceBytes
        self.includeStaleEvidence = includeStaleEvidence
    }
}

public struct ASKWorkWikiReportPlan: Sendable, Equatable {
    public var evidencePack: ASKEvidencePack
    public var projectionWrite: ProjectionWrite
    public var patch: KnowledgePatchPlan

    public init(evidencePack: ASKEvidencePack, projectionWrite: ProjectionWrite, patch: KnowledgePatchPlan) {
        self.evidencePack = evidencePack
        self.projectionWrite = projectionWrite
        self.patch = patch
    }
}


public struct ASKWorkWikiReportApprovalRequest: Sendable, Equatable {
    public var patchID: String
    public var decidedBy: String
    public var decidedAt: String
    public var reason: String
    public var requireFreshEvidence: Bool

    public init(
        patchID: String,
        decidedBy: String,
        decidedAt: String,
        reason: String,
        requireFreshEvidence: Bool = true
    ) {
        self.patchID = patchID
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
        self.reason = reason
        self.requireFreshEvidence = requireFreshEvidence
    }
}

public struct ASKWorkWikiReportApprovalSourceStatus: Codable, Sendable, Equatable {
    public var sourceID: String
    public var freshness: String
    public var sourcePath: String?

    public init(sourceID: String, freshness: String, sourcePath: String?) {
        self.sourceID = sourceID
        self.freshness = freshness
        self.sourcePath = sourcePath
    }
}

public struct ASKWorkWikiReportApprovalResult: Sendable, Equatable {
    public var patch: KnowledgePatchPlan
    public var verification: VerificationReport
    public var receipt: PatchDecisionReceipt
    public var sourceStatuses: [ASKWorkWikiReportApprovalSourceStatus]
    public var applySummary: ASKApplySummary

    public init(
        patch: KnowledgePatchPlan,
        verification: VerificationReport,
        receipt: PatchDecisionReceipt,
        sourceStatuses: [ASKWorkWikiReportApprovalSourceStatus],
        applySummary: ASKApplySummary
    ) {
        self.patch = patch
        self.verification = verification
        self.receipt = receipt
        self.sourceStatuses = sourceStatuses
        self.applySummary = applySummary
    }
}

public struct ASKWorkWikiReportRejectionRequest: Sendable, Equatable {
    public var patchID: String
    public var decidedBy: String
    public var decidedAt: String
    public var reason: String

    public init(
        patchID: String,
        decidedBy: String,
        decidedAt: String,
        reason: String
    ) {
        self.patchID = patchID
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
        self.reason = reason
    }
}

public struct ASKWorkWikiReportRejectionResult: Sendable, Equatable {
    public var patch: KnowledgePatchPlan
    public var verification: VerificationReport
    public var receipt: PatchDecisionReceipt
    public var applySummary: ASKApplySummary

    public init(
        patch: KnowledgePatchPlan,
        verification: VerificationReport,
        receipt: PatchDecisionReceipt,
        applySummary: ASKApplySummary
    ) {
        self.patch = patch
        self.verification = verification
        self.receipt = receipt
        self.applySummary = applySummary
    }
}

public struct ASKWorkWikiCaptureRequest: Sendable, Equatable {
    public var captureManifestPath: URL
    public var domain: String
    public var requestedAt: String
    public var focusPrompt: String?

    public init(
        captureManifestPath: URL,
        domain: String,
        requestedAt: String,
        focusPrompt: String? = nil
    ) {
        self.captureManifestPath = captureManifestPath
        self.domain = domain
        self.requestedAt = requestedAt
        self.focusPrompt = focusPrompt
    }
}

public struct ASKWorkWikiCapturePlan: Sendable, Equatable {
    public var importedCapture: ASKImportedCapture
    public var ingestRequest: IngestEvidenceRequest
    public var patch: KnowledgePatchPlan

    public init(
        importedCapture: ASKImportedCapture,
        ingestRequest: IngestEvidenceRequest,
        patch: KnowledgePatchPlan
    ) {
        self.importedCapture = importedCapture
        self.ingestRequest = ingestRequest
        self.patch = patch
    }
}

public struct ASKWorkWikiDoctorRequest: Sendable, Equatable {
    public var evidenceFilter: ASKEvidenceFilter
    public var includeASKLint: Bool
    public var checkPendingPatches: Bool
    public var checkEvidenceFreshness: Bool
    public var checkIndexedReports: Bool
    public var checkStorageHealth: Bool

    public init(
        evidenceFilter: ASKEvidenceFilter = ASKEvidenceFilter(scopes: [.work]),
        includeASKLint: Bool = true,
        checkPendingPatches: Bool = true,
        checkEvidenceFreshness: Bool = true,
        checkIndexedReports: Bool = true,
        checkStorageHealth: Bool = true
    ) {
        self.evidenceFilter = evidenceFilter
        self.includeASKLint = includeASKLint
        self.checkPendingPatches = checkPendingPatches
        self.checkEvidenceFreshness = checkEvidenceFreshness
        self.checkIndexedReports = checkIndexedReports
        self.checkStorageHealth = checkStorageHealth
    }
}

public struct ASKWorkWikiDoctorFinding: Codable, Sendable, Equatable {
    public var kind: String
    public var severity: String
    public var count: Int
    public var items: [String]

    public init(kind: String, severity: String, count: Int, items: [String] = []) {
        self.kind = kind
        self.severity = severity
        self.count = count
        self.items = items
    }
}

public struct ASKWorkWikiDoctorReport: Codable, Sendable, Equatable {
    public var findingCount: Int
    public var findings: [ASKWorkWikiDoctorFinding]
    public var storageHealth: ASKStorageHealthReport?

    public init(findings: [ASKWorkWikiDoctorFinding], storageHealth: ASKStorageHealthReport? = nil) {
        self.findings = findings
        self.findingCount = findings.count
        self.storageHealth = storageHealth
    }
}

public struct ASKWorkWikiCloseDayRequest: Sendable, Equatable {
    public var date: String
    public var queryText: String
    public var requestedAt: String
    public var slug: String?
    public var subjectID: String?
    public var filter: ASKEvidenceFilter
    public var maxEvidenceBytes: Int
    public var includeStaleEvidence: Bool

    public init(
        date: String,
        queryText: String? = nil,
        requestedAt: String,
        slug: String? = nil,
        subjectID: String? = nil,
        filter: ASKEvidenceFilter = ASKEvidenceFilter(scopes: [.work], kinds: [.worklog, .log]),
        maxEvidenceBytes: Int = 262_144,
        includeStaleEvidence: Bool = false
    ) {
        self.date = date
        self.queryText = queryText ?? ""
        self.requestedAt = requestedAt
        self.slug = slug
        self.subjectID = subjectID
        self.filter = filter
        self.maxEvidenceBytes = maxEvidenceBytes
        self.includeStaleEvidence = includeStaleEvidence
    }
}

public struct ASKWorkWikiCloseDaySummary: Codable, Sendable, Equatable {
    public var done: [String]
    public var blockers: [String]
    public var decisions: [String]
    public var next: [String]

    public init(done: [String] = [], blockers: [String] = [], decisions: [String] = [], next: [String] = []) {
        self.done = done
        self.blockers = blockers
        self.decisions = decisions
        self.next = next
    }
}

public struct ASKWorkWikiCloseDayPlan: Sendable, Equatable {
    public var evidencePack: ASKEvidencePack
    public var summary: ASKWorkWikiCloseDaySummary
    public var projectionWrite: ProjectionWrite
    public var patch: KnowledgePatchPlan

    public init(
        evidencePack: ASKEvidencePack,
        summary: ASKWorkWikiCloseDaySummary,
        projectionWrite: ProjectionWrite,
        patch: KnowledgePatchPlan
    ) {
        self.evidencePack = evidencePack
        self.summary = summary
        self.projectionWrite = projectionWrite
        self.patch = patch
    }
}
