import Foundation
import NativeAgentDomain
import NativeAgentSkills

public enum EvolutionSkillApplyOperation: String, Codable, Sendable, Equatable {
    case imported
    case updated
    case cloned
}

public struct EvolutionSkillApplyResult: Codable, Sendable, Equatable {
    public let proposalID: String
    public let runID: String
    public let operation: EvolutionSkillApplyOperation
    public let skill: ManagedSkill
    public let approval: EvolutionSkillApplyApproval
    public let appliedAt: Date
    public let metadata: [String: JSONValue]

    public init(
        proposalID: String,
        runID: String,
        operation: EvolutionSkillApplyOperation,
        skill: ManagedSkill,
        approval: EvolutionSkillApplyApproval,
        appliedAt: Date,
        metadata: [String: JSONValue] = [:]
    ) {
        self.proposalID = proposalID
        self.runID = runID
        self.operation = operation
        self.skill = skill
        self.approval = approval
        self.appliedAt = appliedAt
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case proposalID = "proposal_id"
        case runID = "run_id"
        case operation
        case skill
        case approval
        case appliedAt = "applied_at"
        case metadata
    }
}
