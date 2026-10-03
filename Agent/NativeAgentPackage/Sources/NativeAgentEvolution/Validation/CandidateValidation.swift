import Foundation

public struct MobileEvolutionCandidateValidator: Sendable {
    public static let minimumMaximumCharacters = 1_024
    public static let standardMaximumCharacters = 64_000

    public let maxCharacters: Int

    public init(maxCharacters: Int = Self.standardMaximumCharacters) {
        self.maxCharacters = max(Self.minimumMaximumCharacters, maxCharacters)
    }

    public func validate(_ candidate: EvolutionCandidate) throws {
        guard !candidate.id.trimmedForNativeAgentEvolution.isEmpty else {
            throw EvolutionError.invalidCandidate("candidate id is required")
        }
        guard !candidate.content.trimmedForNativeAgentEvolution.isEmpty else {
            throw EvolutionError.invalidCandidate("candidate \"\(candidate.id)\" has empty content")
        }
        guard candidate.content.count <= maxCharacters else {
            throw EvolutionError.invalidCandidate("candidate \"\(candidate.id)\" exceeds maxCharacters=\(maxCharacters)")
        }
        let lowered = candidate.content.lowercased()
        if lowered.contains("silent mutation") || lowered.contains("bypass approval") {
            throw EvolutionError.invalidCandidate("candidate \"\(candidate.id)\" violates mobile approval policy")
        }
    }
}
