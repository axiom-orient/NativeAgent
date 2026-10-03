import NativeAgentDomain
import Foundation

struct EvolutionReportStoragePlan: Sendable, Equatable {
    let storedReport: EvolutionReport
    let applyProposal: EvolutionApplyProposal?
    let candidateFileNames: [String]
}

struct EvolutionReportStoragePlanner: Sendable {
    func plan(
        report: EvolutionReport,
        destinationPath: String
    ) throws -> EvolutionReportStoragePlan {
        let stored = report.storing(at: destinationPath)
        let proposal: EvolutionApplyProposal?
        if stored.selectedCandidateID == nil {
            proposal = nil
        } else {
            proposal = try stored.makeApplyProposal()
        }

        let candidateFileNames = stored.candidates.map {
            "\(EvolutionPath.sanitized($0.candidate.id)).txt"
        }
        guard Set(candidateFileNames).count == candidateFileNames.count else {
            throw EvolutionError.storeFailure(
                "candidate ids collide after filesystem path sanitization")
        }
        return EvolutionReportStoragePlan(
            storedReport: stored,
            applyProposal: proposal,
            candidateFileNames: candidateFileNames
        )
    }
}
