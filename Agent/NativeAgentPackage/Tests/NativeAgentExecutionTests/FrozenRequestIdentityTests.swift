import Foundation
import Testing
import NativeAgentDomain
import NativeAgentTestSupport
@testable import NativeAgentExecution
@testable import NativeAgentStore

private actor RequestIdentityProbe: ModelClient {
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        scriptedModelEvents(descriptor: modelDescriptor) { try await self.generate(request: request) }
    }

    nonisolated let providerID = "identity.probe"
    private var requests: [ModelRequest] = []
    func generate(request: ModelRequest) async throws -> ModelTurn {
        requests.append(request)
        throw EffectFailure.outcomeUnknown(operation: "model.generate", cause: "injected lost response")
    }
    func observed() -> [ModelRequest] { requests }
}

@Test func frozenRequestDigestMatchesProviderEntryAndReopenDoesNotExecuteAgain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = RequestIdentityProbe()
    let store = ApplicationSupportSessionStore(rootURL: root)
    let coordinator = try SessionCoordinator(modelClient: model, approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: store, toolPacks: [], configuration: .agentDefault)
    do {
        _ = try await coordinator.startSession(sessionID: "identity", userPrompt: "exact input 한국어")
        Issue.record("Injected lost response returned success")
    } catch let error as ModelGenerationFailure {
        #expect(error.code == .transportFailure)
    }
    let first = try #require(try await store.loadSnapshot(sessionID: "identity"))
    #expect(first.status == .waiting)
    let pending = try #require(try await coordinator.pendingModelInvocation(sessionID: "identity"))
    let record = try #require(try await store.loadEffect(sessionID: "identity", scope: .modelInvocation, key: pending.id))
    let recordedDigest = try #require(record.input["semanticRequestSHA256"]?.stringValue)
    let observed = try #require(await model.observed().first)
    #expect(try ModelInvocationLedger.semanticRequestDigest(observed) == recordedDigest)
    #expect(observed == pending.request)
    let reopenedStore = ApplicationSupportSessionStore(rootURL: root)
    let reopened = try SessionCoordinator(modelClient: model, approvalRouter: DenyAllApprovalRouter(),
        runtimeStore: reopenedStore, toolPacks: [], configuration: .agentDefault)
    await #expect(throws: AgentError.self) {
        _ = try await reopened.run(sessionID: "identity")
    }
    let again = try #require(try await reopened.pendingModelInvocation(sessionID: "identity"))
    #expect(again.request == observed)
    #expect(await model.observed().count == 1)
    let completed = try await reopened.resolvePendingModelInvocation(sessionID: "identity", invocationID: again.id,
        resolution: .completed(ModelTurn(content: "host verified result")))
    #expect(completed.status == .completed)
    #expect(await model.observed().count == 1)
}
