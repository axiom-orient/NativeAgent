import Foundation
import KnowledgeCore
import KnowledgeRuntime

extension ASKIOSFMFKernel {
    public func importCollected(_ manifestPath: URL) throws -> ASKImportedCapture {
        try runtime.importCollected(manifestPath)
    }

    public func planEvidenceIngest(_ request: IngestEvidenceRequest) throws -> IngestEvidenceOutcome {
        try runtime.planEvidenceIngest(request)
    }

    public func importCollectedAndPlan(manifestPath: URL, domain: String, requestedAt: String, focusPrompt: String? = nil) throws -> IngestEvidenceOutcome {
        try runtime.importCollectedAndPlan(manifestPath: manifestPath, domain: domain, requestedAt: requestedAt, focusPrompt: focusPrompt)
    }
}
