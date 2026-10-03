import Foundation
import NativeAgentDomain
import NativeAgentEvolution
import NativeAgentSkills

public struct EvolutionSkillApplyAdapter: Sendable {
    private static let maximumCloneSuffix = 50

    private let library: SkillLibrary
    private let now: @Sendable () -> Date

    public init(
        library: SkillLibrary,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.now = now
    }

    @discardableResult
    public func applyApprovedProposal(
        _ proposal: EvolutionApplyProposal,
        approval: EvolutionSkillApplyApproval,
        options: EvolutionSkillApplyOptions = EvolutionSkillApplyOptions()
    ) async throws -> EvolutionSkillApplyResult {
        try validate(proposal: proposal, approval: approval)

        let requestedSkillName = Self.normalizedSkillName(
            options.skillName
                ?? proposal.metadata["skill_name"]?.stringValue
                ?? proposal.metadata["skillName"]?.stringValue
                ?? proposal.sourceID
        )
        guard !requestedSkillName.isEmpty else {
            throw EvolutionSkillApplyError.invalidProposal("proposal does not identify a skill name")
        }

        let requestedExisting = try await library.skill(named: requestedSkillName)
        let protectedSource = requestedExisting.map { $0.builtIn || $0.source.kind != .imported } ?? false
        let targetSkillName = protectedSource
            ? try await availableCloneName(for: requestedSkillName, candidateID: proposal.candidateID)
            : requestedSkillName
        let targetExisting = protectedSource ? nil : requestedExisting

        var mutationPreconditions: [SkillDocumentMutationPrecondition] = []
        if requestedExisting != nil {
            mutationPreconditions.append(
                .instructions(name: requestedSkillName, expected: proposal.beforeContent)
            )
        } else {
            mutationPreconditions.append(.absent(name: requestedSkillName))
        }
        if protectedSource {
            mutationPreconditions.append(.absent(name: targetSkillName))
        }

        let upsert: CustomTextSkillUpsertResult
        do {
            upsert = try await library.upsertCustomTextSkill(
                name: targetSkillName,
                description: options.description ?? targetExisting?.description ?? defaultDescription(for: proposal),
                instructions: proposal.afterContent,
                requiresSecret: options.requiresSecret ?? targetExisting?.requiresSecret ?? false,
                requiresSecretDescription: options.requiresSecretDescription ?? targetExisting?.requiresSecretDescription ?? "",
                homepage: options.homepage ?? targetExisting?.homepage ?? "",
                selected: options.selected,
                scripts: options.scripts,
                assets: options.assets,
                binaryAssets: options.binaryAssets,
                mutationPreconditions: mutationPreconditions
            )
        } catch let conflict as SkillDocumentMutationConflict {
            throw EvolutionSkillApplyError.invalidProposal(
                "proposal base is stale: \(conflict.message)"
            )
        }

        let operation: EvolutionSkillApplyOperation
        if protectedSource {
            operation = .cloned
        } else {
            operation = upsert.operation == .created ? .imported : .updated
        }
        return EvolutionSkillApplyResult(
            proposalID: proposal.id,
            runID: proposal.runID,
            operation: operation,
            skill: upsert.skill,
            approval: approval,
            appliedAt: now(),
            metadata: [
                "source_id": .string(proposal.sourceID),
                "candidate_id": .string(proposal.candidateID),
                "review_only_source": .bool(true),
                "requested_skill_name": .string(requestedSkillName),
                "target_skill_name": .string(targetSkillName),
                "protected_source_cloned": .bool(protectedSource),
                "source_kind": requestedExisting.map { .string($0.source.kind.rawValue) } ?? .null
            ]
        )
    }


    private func validate(
        proposal: EvolutionApplyProposal,
        approval: EvolutionSkillApplyApproval
    ) throws {
        guard proposal.status == .pendingHostApproval else {
            throw EvolutionSkillApplyError.invalidProposal("proposal must be pending host approval")
        }
        guard proposal.requiresHostApproval else { throw EvolutionSkillApplyError.approvalRequired }
        guard !approval.approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvolutionSkillApplyError.invalidProposal("approvalID is required")
        }
        guard !approval.reviewerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvolutionSkillApplyError.invalidProposal("reviewerID is required")
        }
        if let proposalID = approval.proposalID, proposalID != proposal.id {
            throw EvolutionSkillApplyError.invalidProposal("approval proposalID does not match proposal id")
        }
        guard approval.approved else { throw EvolutionSkillApplyError.denied(approval.reason) }
        let before = proposal.beforeContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = proposal.afterContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !after.isEmpty else {
            throw EvolutionSkillApplyError.invalidProposal("proposal afterContent must not be empty")
        }
        guard before != after else {
            throw EvolutionSkillApplyError.invalidProposal("proposal beforeContent and afterContent must differ")
        }
    }

    private func availableCloneName(for requestedSkillName: String, candidateID: String) async throws -> String {
        let requested = Self.normalizedSkillName(requestedSkillName)
        let candidate = Self.normalizedSkillName(candidateID)
        let base = Self.normalizedSkillName("evolved-\(requested)")
        let fallback = candidate.isEmpty ? base : Self.normalizedSkillName("\(base)-\(candidate)")
        var candidates = [base]
        if fallback != base { candidates.append(fallback) }
        candidates.append(contentsOf: (2...Self.maximumCloneSuffix).map { "\(fallback)-\($0)" })
        for name in candidates where !name.isEmpty {
            if try await library.skill(named: name) == nil {
                return name
            }
        }
        throw EvolutionSkillApplyError.invalidProposal("could not allocate a unique evolved skill clone name for \(requested)")
    }

    private func defaultDescription(for proposal: EvolutionApplyProposal) -> String {
        let source = proposal.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            return "Evolved mobile skill from \(source)"
        }
        return "Evolved mobile skill"
    }

    static func normalizedSkillName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
