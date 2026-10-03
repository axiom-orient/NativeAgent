import Foundation

public enum EvolutionSkillApplyError: Error, LocalizedError, Sendable, Equatable {
    case approvalRequired
    case denied(String?)
    case invalidProposal(String)
    case bundledSkillUpdateForbidden(String)

    public var errorDescription: String? {
        switch self {
        case .approvalRequired:
            "host approval is required before applying an evolution proposal"
        case .denied(let reason):
            reason.map { "host approval denied: \($0)" } ?? "host approval denied"
        case .invalidProposal(let message):
            message
        case .bundledSkillUpdateForbidden(let skillName):
            "bundled skill \"\(skillName)\" cannot be updated in place"
        }
    }
}
