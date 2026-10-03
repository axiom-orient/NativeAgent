import Foundation

public enum ASKProductIntegrationError: Error, Equatable, Sendable {
    case invalidPresentationBundleName(String)
    case projectionNotFound(String)
    case presentationNotMaterialized(String)
    case failedToWritePresentationMarkdown(String)
    case failedToWritePresentationDocument(String)
    case failedToWritePresentationManifest(String)
    case invalidASKSourceID(String)
    case invalidTutorInsightCandidateID(String)
    case invalidTutorInsightPrompt(String)
    case invalidTutorInsightTimestamp(String)
    case tutorSessionMismatch(expected: String, actual: String)
    case tutorPracticeSetMismatch(expectedSessionID: String, actualSessionID: String)
    case tutorPracticeEvaluationMismatch(expectedPracticeSetID: String, actualPracticeSetID: String)
    case tutorInsightCandidateNotFound(String)
}
