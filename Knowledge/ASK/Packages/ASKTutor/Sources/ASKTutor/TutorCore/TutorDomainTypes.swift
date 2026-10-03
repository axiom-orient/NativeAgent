import Foundation

public enum TutorIntent: String, Codable, Sendable, Equatable {
    case explain
    case solve
    case practice
    case review
    case plan
}

public enum TutorScope: Codable, Sendable, Equatable {
    case global
    case projection(slug: String)
    case subject(kind: String, id: String)

    public var projectionSlug: String? {
        switch self {
        case let .projection(slug):
            return slug
        default:
            return nil
        }
    }
}

public enum TutorTranscriptRole: String, Codable, Sendable, Equatable {
    case user
    case tutor
    case system
}

public enum TutorResponseStyle: String, Codable, Sendable, Equatable {
    case concise
    case standard
    case deep
}

public enum TutorMasteryLevel: String, Codable, Sendable, Equatable {
    case unseen
    case exposed
    case practiced
    case strong
    case mastered
}
