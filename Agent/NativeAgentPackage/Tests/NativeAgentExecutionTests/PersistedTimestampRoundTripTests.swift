import NativeAgentTestSupport
import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore

private struct SubmillisecondTimestampModelClient: ModelClient {
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        scriptedModelEvents(descriptor: modelDescriptor) { try await self.generate(request: request) }
    }

    let providerID = "provider.timestamp-round-trip"
    let timestamp: Date

    func generate(request: ModelRequest) async throws -> ModelTurn {
        ModelTurn(content: "done")
    }
}

@Test
func coordinatorReturnsExactlyReloadableSnapshotAtPersistencePrecision() async throws {
    let sourceTimestamp = Date(timeIntervalSince1970: 1_067_557_142.463_554_4)
    let expectedTimestamp = PersistedTimestamp.canonicalizing(sourceTimestamp)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent-timestamp-round-trip-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ApplicationSupportSessionStore(rootURL: root)
    let coordinator = try SessionCoordinator(
        modelClient: SubmillisecondTimestampModelClient(timestamp: sourceTimestamp),
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        now: { sourceTimestamp }
    )

    let returned = try await coordinator.startSession(userPrompt: "round trip")
    let reloaded = try await coordinator.loadSession(sessionID: returned.sessionID)

    #expect(returned == reloaded)
    #expect(returned.createdAt == expectedTimestamp)
    #expect(returned.updatedAt == expectedTimestamp)
    #expect(returned.messages.allSatisfy { $0.createdAt == expectedTimestamp })
}
