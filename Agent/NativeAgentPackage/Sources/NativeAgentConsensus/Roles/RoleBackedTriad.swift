import Foundation

public struct RoleBackedTriad: Sendable {
    public let triad: Triad

    public init(
        constructor: any ConsensusRoleDriver,
        verifier: any ConsensusRoleDriver,
        challenger: any ConsensusRoleDriver,
        policy: ConsensusTriadPolicy = .init()
    ) {
        self.triad = Triad(
            constructor: DriverConstructorAdapter(driver: constructor, policy: policy.constructor),
            verifier: DriverVerifierAdapter(driver: verifier, policy: policy.verifier),
            challenger: DriverChallengerAdapter(driver: challenger, policy: policy.challenger)
        )
    }
}

private func executeRoleRequest<A: Decodable>(
    driver: any ConsensusRoleDriver,
    role: ConsensusRole,
    input: RoundInput,
    policy: ConsensusRolePolicy
) async throws -> A {
    let response = try await driver.generate(
        request: ConsensusRolePromptFactory.makeRequest(role: role, input: input, policy: policy)
    )
    return try ConsensusRoleJSON.decode(A.self, from: response.text, role: role.rawValue)
}

private struct DriverConstructorAdapter: Constructor, Sendable {
    let driver: any ConsensusRoleDriver
    let policy: ConsensusRolePolicy

    func propose(input: RoundInput) async throws -> ProposalArtifact {
        try await executeRoleRequest(driver: driver, role: .constructor, input: input, policy: policy)
    }
}

private struct DriverVerifierAdapter: Verifier, Sendable {
    let driver: any ConsensusRoleDriver
    let policy: ConsensusRolePolicy

    func review(input: RoundInput) async throws -> ReviewArtifact {
        try await executeRoleRequest(driver: driver, role: .verifier, input: input, policy: policy)
    }
}

private struct DriverChallengerAdapter: Challenger, Sendable {
    let driver: any ConsensusRoleDriver
    let policy: ConsensusRolePolicy

    func challenge(input: RoundInput) async throws -> ChallengeArtifact {
        try await executeRoleRequest(driver: driver, role: .challenger, input: input, policy: policy)
    }
}
