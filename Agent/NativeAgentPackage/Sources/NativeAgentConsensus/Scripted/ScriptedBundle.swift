import Foundation

public struct ScriptedBundle: Codable, Sendable, Equatable {
    public let problem: ProblemPacket
    public let constructor: [ProposalArtifact]
    public let verifier: [ReviewArtifact]
    public let challenger: [ChallengeArtifact]

    public init(
        problem: ProblemPacket,
        constructor: [ProposalArtifact],
        verifier: [ReviewArtifact],
        challenger: [ChallengeArtifact]
    ) {
        self.problem = problem
        self.constructor = constructor
        self.verifier = verifier
        self.challenger = challenger
    }

    public var triad: Triad {
        Triad(
            constructor: ScriptedConstructor(rounds: constructor),
            verifier: ScriptedVerifier(rounds: verifier),
            challenger: ScriptedChallenger(rounds: challenger)
        )
    }

    public static func decode(data: Data) throws -> ScriptedBundle {
        try JSONCoding.decoder().decode(ScriptedBundle.self, from: data)
    }

    public static func decode(string: String) throws -> ScriptedBundle {
        try decode(data: Data(string.utf8))
    }
}
