import Foundation
import Testing
import NativeAgentDomain
import NativeAgentConsensus
import LanguageModelRuntime

private struct StandaloneConsensusBase: ModelClient {
    let providerID = "standalone"
    var invocationSemantics: ModelClientInvocationSemantics { .standaloneOnly }
    func generate(request: ModelRequest) async throws -> ModelTurn {
        Issue.record("Forbidden base executed")
        throw CancellationError()
    }
}
@Test func consensusCannotHideStandaloneOnlyBase() throws {
    let bundle = ScriptedBundle(problem: ProblemPacket(objective: "check", observedIssue: "boundary", primaryClass: "logic"),
        constructor: [ProposalArtifact(summary: "proposal")],
        verifier: [ReviewArtifact(summary: "review", verdict: .pass)],
        challenger: [ChallengeArtifact(summary: "challenge", verdict: .clear)])
    let client = ConsensusRoutingModelClient(base: StandaloneConsensusBase(), runner: ConsensusRunner(triad: bundle.triad))
    #expect(client.invocationSemantics == .standaloneOnly)
    do {
        _ = try ModelRuntime(id: .init(rawValue: "forbidden-routing"), client: client)
        Issue.record("Routing hid forbidden decoration")
    } catch let error as ModelRuntimeFailure {
        #expect(error.code == .invalidConfiguration)
    }
}
