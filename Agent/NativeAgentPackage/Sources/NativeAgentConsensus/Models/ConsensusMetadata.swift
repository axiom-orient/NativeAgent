import Foundation
import NativeAgentDomain

public enum ConsensusMode: String, Codable, Sendable, Equatable {
    case disabled
    case required
}

public enum ConsensusMetadataKeys {
    public static let mode = "native-agent.consensus.mode"
    public static let problem = "native-agent.consensus.problem"
    public static let maxRounds = "native-agent.consensus.maxRounds"
    public static let maxRequiredSteps = "native-agent.consensus.maxRequiredSteps"
    public static let registryQueryLimit = "native-agent.consensus.registryQueryLimit"

    public static let roleSession = "native-agent.consensus.role"
    public static let roleTemperature = "native-agent.consensus.role.temperature"
    public static let roleMaxTokens = "native-agent.consensus.role.maxTokens"
    public static let roleJSONSchema = "native-agent.consensus.role.jsonSchema"

    public static let result = "native-agent.consensus.result"
    public static let decision = "native-agent.consensus.decision"
    public static let rounds = "native-agent.consensus.rounds"
    public static let escalated = "native-agent.consensus.escalated"
}

public enum ConsensusMetadataError: Error, Equatable {
    case missingProblemPacket
    case invalidProblemPacket
}

public struct ConsensusRunOptions: Codable, Sendable, Equatable {
    public let maxRounds: Int
    public let maxRequiredSteps: Int
    public let registryQueryLimit: Int

    public init(
        maxRounds: Int = 2,
        maxRequiredSteps: Int = 3,
        registryQueryLimit: Int = 3
    ) {
        self.maxRounds = maxRounds
        self.maxRequiredSteps = maxRequiredSteps
        self.registryQueryLimit = registryQueryLimit
    }
}

public struct ConsensusExecutionPlan: Sendable {
    public let problem: ProblemPacket
    public let options: ConsensusRunOptions

    public init(problem: ProblemPacket, options: ConsensusRunOptions = .init()) {
        self.problem = problem
        self.options = options
    }
}

public enum ConsensusMetadata {
    public static func required(
        problem: ProblemPacket,
        options: ConsensusRunOptions = .init()
    ) throws -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            ConsensusMetadataKeys.mode: .string(ConsensusMode.required.rawValue),
            ConsensusMetadataKeys.problem: try JSONValue.encode(problem)
        ]

        metadata[ConsensusMetadataKeys.maxRounds] = .integer(Int64(options.maxRounds))
        metadata[ConsensusMetadataKeys.maxRequiredSteps] = .integer(Int64(options.maxRequiredSteps))
        metadata[ConsensusMetadataKeys.registryQueryLimit] = .integer(Int64(options.registryQueryLimit))
        return metadata
    }

    static func executionPlan(from metadata: [String: JSONValue]) throws -> ConsensusExecutionPlan? {
        if metadata[ConsensusMetadataKeys.roleSession]?.boolValue == true {
            return nil
        }

        let mode = metadata[ConsensusMetadataKeys.mode]?.stringValue.flatMap(ConsensusMode.init(rawValue:)) ?? .disabled
        guard mode == .required else {
            return nil
        }

        guard let rawProblem = metadata[ConsensusMetadataKeys.problem] else {
            throw ConsensusMetadataError.missingProblemPacket
        }
        let problem = try rawProblem.decode(ProblemPacket.self)

        let options = ConsensusRunOptions(
            maxRounds: max(1, metadata[ConsensusMetadataKeys.maxRounds]?.intValue ?? 2),
            maxRequiredSteps: max(1, metadata[ConsensusMetadataKeys.maxRequiredSteps]?.intValue ?? 3),
            registryQueryLimit: max(1, metadata[ConsensusMetadataKeys.registryQueryLimit]?.intValue ?? 3)
        )

        return ConsensusExecutionPlan(problem: problem, options: options)
    }

    static func resultMetadata(_ result: BACResult) throws -> [String: JSONValue] {
        [
            ConsensusMetadataKeys.escalated: .bool(true),
            ConsensusMetadataKeys.decision: .string(result.final.decision.rawValue),
            ConsensusMetadataKeys.rounds: .integer(Int64(result.rounds.count)),
            ConsensusMetadataKeys.result: try JSONValue.encode(result)
        ]
    }
}
