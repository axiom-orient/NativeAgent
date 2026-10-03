import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentEvolution
@testable import NativeAgentEvolutionSkills
@testable import NativeAgentSkills

private func adapterTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func makeProposal(
    sourceID: String = "mobile-skill",
    before: String = "old instructions",
    after: String = "new instructions"
) -> EvolutionApplyProposal {
    EvolutionApplyProposal(
        id: "proposal-1",
        runID: "run-1",
        sourceID: sourceID,
        sourceName: sourceID,
        candidateID: "candidate-1",
        candidateTitle: "Candidate",
        rationale: "improves mobile behavior",
        baselineValidationScore: 0.2,
        candidateValidationScore: 0.9,
        beforeContent: before,
        afterContent: after,
        recommendation: "review_only: selected",
        requiresHostApproval: true,
        status: .pendingHostApproval
    )
}

private func makeLibrary(root: URL) -> SkillLibrary {
    SkillLibrary(
        workspace: SkillWorkspace(
            supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
            userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
        )
    )
}

@Test
func approvedEvolutionProposalImportsCustomSkill() async throws {
    let root = adapterTempRoot()
    let library = makeLibrary(root: root)
    let adapter = EvolutionSkillApplyAdapter(library: library)

    let result = try await adapter.applyApprovedProposal(
        makeProposal(sourceID: "Mobile Skill"),
        approval: EvolutionSkillApplyApproval(
            approvalID: "approval-1",
            reviewerID: "host-user",
            approved: true,
            reason: "reviewed"
        )
    )

    #expect(result.operation == .imported)
    #expect(result.skill.name == "mobile-skill")
    #expect(result.skill.instructions == "new instructions")
    #expect(try await library.skill(named: "mobile-skill")?.instructions == "new instructions")
}

@Test
func approvedEvolutionProposalUpdatesExistingImportedSkill() async throws {
    let root = adapterTempRoot()
    let library = makeLibrary(root: root)
    _ = try await library.addCustomTextSkill(
        name: "Mobile Skill",
        description: "Existing",
        instructions: "old instructions",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: ""
    )
    let adapter = EvolutionSkillApplyAdapter(library: library)

    let result = try await adapter.applyApprovedProposal(
        makeProposal(sourceID: "mobile-skill", after: "updated instructions"),
        approval: EvolutionSkillApplyApproval(
            approvalID: "approval-2",
            reviewerID: "host-user",
            approved: true
        )
    )

    #expect(result.operation == .updated)
    #expect(try await library.skill(named: "mobile-skill")?.instructions == "updated instructions")
}

@Test
func evolutionProposalRequiresPositiveHostApproval() async throws {
    let library = makeLibrary(root: adapterTempRoot())
    let adapter = EvolutionSkillApplyAdapter(library: library)

    await #expect(throws: EvolutionSkillApplyError.self) {
        _ = try await adapter.applyApprovedProposal(
            makeProposal(),
            approval: EvolutionSkillApplyApproval(
                approvalID: "approval-denied",
                reviewerID: "host-user",
                approved: false,
                reason: "not safe"
            )
        )
    }
}

@Test
func approvalProposalIDMismatchIsRejected() async throws {
    let library = makeLibrary(root: adapterTempRoot())
    let adapter = EvolutionSkillApplyAdapter(library: library)
    let proposal = makeProposal()

    await #expect(throws: EvolutionSkillApplyError.self) {
        _ = try await adapter.applyApprovedProposal(
            proposal,
            approval: EvolutionSkillApplyApproval(
                approvalID: "approval-mismatch",
                reviewerID: "host-user",
                approved: true,
                proposalID: "other-proposal"
            )
        )
    }
}

@Test
func noOpEvolutionProposalIsRejected() async throws {
    let library = makeLibrary(root: adapterTempRoot())
    let adapter = EvolutionSkillApplyAdapter(library: library)

    await #expect(throws: EvolutionSkillApplyError.self) {
        _ = try await adapter.applyApprovedProposal(
            makeProposal(before: "same", after: "same"),
            approval: EvolutionSkillApplyApproval(
                approvalID: "approval-noop",
                reviewerID: "host-user",
                approved: true,
                proposalID: "proposal-1"
            )
        )
    }
}

@Test
func staleEvolutionProposalCannotOverwriteCurrentImportedSkill() async throws {
    let root = adapterTempRoot()
    let library = makeLibrary(root: root)
    _ = try await library.addCustomTextSkill(
        name: "Mobile Skill",
        description: "Existing",
        instructions: "current instructions",
        requiresSecret: false,
        requiresSecretDescription: "",
        homepage: ""
    )
    let adapter = EvolutionSkillApplyAdapter(library: library)

    await #expect(throws: EvolutionSkillApplyError.self) {
        _ = try await adapter.applyApprovedProposal(
            makeProposal(
                sourceID: "mobile-skill",
                before: "stale instructions",
                after: "candidate instructions"
            ),
            approval: EvolutionSkillApplyApproval(
                approvalID: "approval-stale",
                reviewerID: "host-user",
                approved: true,
                proposalID: "proposal-1"
            )
        )
    }

    #expect(try await library.skill(named: "mobile-skill")?.instructions == "current instructions")
}
