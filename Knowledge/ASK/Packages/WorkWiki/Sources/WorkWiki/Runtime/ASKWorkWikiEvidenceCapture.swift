import Foundation
import KnowledgeRuntime

public enum ASKWorkWikiEvidenceCapture {
    public static func validate(_ request: ASKWorkWikiCaptureRequest) throws {
        guard !request.captureManifestPath.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKError.validation("work-wiki capture manifest path must not be empty")
        }
        guard !request.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKError.validation("work-wiki capture domain must not be empty")
        }
        guard ASKTimestamp.isValidRFC3339(request.requestedAt) else {
            throw ASKError.validation("work-wiki capture requested_at must be valid RFC3339")
        }
        if let focusPrompt = request.focusPrompt,
           focusPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ASKError.validation("work-wiki capture focusPrompt must not be empty when provided")
        }
    }
}
