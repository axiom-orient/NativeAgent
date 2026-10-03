import Foundation

public enum Decision: String, Codable, Sendable, Equatable {
    case accept
    case revise
    case abort
}

public enum ReviewVerdict: String, Codable, Sendable, Equatable {
    case pass
    case revise
    case abort
}

public enum ChallengeVerdict: String, Codable, Sendable, Equatable {
    case clear
    case revise
    case abort
}
