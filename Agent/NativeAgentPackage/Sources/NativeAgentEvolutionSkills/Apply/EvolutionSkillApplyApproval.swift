import Foundation
import NativeAgentDomain
import NativeAgentEvolution

public struct EvolutionSkillApplyApproval: Codable, Sendable, Equatable {
    public let approvalID: String
    public let reviewerID: String
    public let approved: Bool
    public let reason: String?
    public let approvedAt: Date
    public let proposalID: String?
    public let correlationID: String?
    public let metadata: [String: JSONValue]

    public init(
        approvalID: String,
        reviewerID: String,
        approved: Bool,
        reason: String? = nil,
        approvedAt: Date = Date(),
        proposalID: String? = nil,
        correlationID: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.approvalID = approvalID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reviewerID = reviewerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.approved = approved
        self.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyForNativeAgentEvolution
        self.approvedAt = approvedAt
        self.proposalID = proposalID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyForNativeAgentEvolution
        self.correlationID = correlationID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyForNativeAgentEvolution
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case approvalID = "approval_id"
        case reviewerID = "reviewer_id"
        case approved
        case reason
        case approvedAt = "approved_at"
        case proposalID = "proposal_id"
        case correlationID = "correlation_id"
        case metadata
    }
}
