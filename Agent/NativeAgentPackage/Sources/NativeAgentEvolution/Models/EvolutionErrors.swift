import Foundation

public enum EvolutionError: Error, LocalizedError, Sendable, Equatable {
    case emptySource
    case emptyDataset
    case noCandidates
    case noSelectedCandidate
    case invalidCandidate(String)
    case storeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .emptySource:
            "source artifact content is required"
        case .emptyDataset:
            "at least one evaluation example is required"
        case .noCandidates:
            "candidate generator returned no candidates"
        case .noSelectedCandidate:
            "evolution report has no selected candidate to propose for host approval"
        case .invalidCandidate(let message):
            message
        case .storeFailure(let message):
            message
        }
    }
}
