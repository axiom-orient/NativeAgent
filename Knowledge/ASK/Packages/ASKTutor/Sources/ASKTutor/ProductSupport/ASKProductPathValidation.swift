import Foundation

package func askProductNormalizedTutorInsightCandidateID(_ candidateID: String) throws -> String {
    let normalized = candidateID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
        throw ASKProductIntegrationError.invalidTutorInsightCandidateID(candidateID)
    }
    guard normalized.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
        throw ASKProductIntegrationError.invalidTutorInsightCandidateID(candidateID)
    }
    return normalized
}
