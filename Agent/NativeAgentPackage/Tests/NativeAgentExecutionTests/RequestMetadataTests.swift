import NativeAgentTestSupport
import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore

private actor RecordingProvider: ModelClient {
    let providerID = "provider.recording"
    private let scriptedTurn: ModelTurn
    private var capturedRequests: [ModelRequest] = []

    init(scriptedTurn: ModelTurn) {
        self.scriptedTurn = scriptedTurn
    }

    func generate(request: ModelRequest) async throws -> ModelTurn {
        capturedRequests.append(request)
        return scriptedTurn
    }

    func lastRequest() -> ModelRequest? {
        capturedRequests.last
    }
}

private func makeRequestMetadataTempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

@Test
func effectiveRequestMetadataUsesMostRecentUserMetadataOnly() {
    let builder = AgentLoopRequestBuilder()
    let snapshot = SessionSnapshot(
        sessionID: "session-1",
        messages: [
            AgentMessage(
                role: .user,
                content: "first",
                metadata: [
                    "shared": .string("older"),
                    "olderOnly": .string("first")
                ]
            ),
            AgentMessage(
                role: .assistant,
                content: "ok"
            ),
            AgentMessage(
                role: .user,
                content: "second",
                metadata: [
                    "shared": .string("latest"),
                    "latestOnly": .string("second")
                ]
            )
        ],
        metadata: [
            "shared": .string("session"),
            "persistedOnly": .string("yes")
        ]
    )

    let metadata = builder.effectiveRequestMetadata(snapshot: snapshot)

    #expect(metadata["shared"]?.stringValue == "latest")
    #expect(metadata["persistedOnly"]?.stringValue == "yes")
    #expect(metadata["olderOnly"] == nil)
    #expect(metadata["latestOnly"]?.stringValue == "second")
}

@Test
func effectiveRequestMetadataReturnsSessionMetadataWhenUserMetadataIsEmpty() {
    let builder = AgentLoopRequestBuilder()
    let snapshot = SessionSnapshot(
        sessionID: "session-1",
        messages: [
            AgentMessage(role: .user, content: "first"),
            AgentMessage(role: .assistant, content: "ok"),
            AgentMessage(role: .user, content: "second", metadata: [:])
        ],
        metadata: [
            "shared": .string("session"),
            "persistedOnly": .string("yes")
        ]
    )

    let metadata = builder.effectiveRequestMetadata(snapshot: snapshot)

    #expect(metadata == snapshot.metadata)
}

@Test
func effectiveRequestMetadataDoesNotReuseOlderRequestMetadata() {
    let builder = AgentLoopRequestBuilder()
    let snapshot = SessionSnapshot(
        sessionID: "session-1",
        messages: [
            AgentMessage(
                role: .user,
                content: "consensus",
                metadata: [
                    "native-agent.consensus.mode": .string("required")
                ]
            ),
            AgentMessage(role: .assistant, content: "Decision: accept"),
            AgentMessage(role: .user, content: "continue normally", metadata: [:])
        ],
        metadata: [
            "persistedOnly": .string("yes")
        ]
    )

    let metadata = builder.effectiveRequestMetadata(snapshot: snapshot)

    #expect(metadata["persistedOnly"]?.stringValue == "yes")
    #expect(metadata["native-agent.consensus.mode"] == nil)
}

@Test
func requestMetadataOverridesSessionMetadataInModelRequest() async throws {
    let provider = RecordingProvider(
        scriptedTurn: ModelTurn(content: "ok")
    )

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: ApplicationSupportSessionStore(rootURL: makeRequestMetadataTempRoot()),
        toolPacks: []
    )

    _ = try await coordinator.startSession(
        userPrompt: "hello",
        metadata: [
            "scope": .string("session"),
            "persistedOnly": .string("yes")
        ],
        requestMetadata: [
            "scope": .string("request"),
            "turnOnly": .string("yes")
        ]
    )

    let request = try #require(await provider.lastRequest())
    #expect(request.metadata["scope"]?.stringValue == "request")
    #expect(request.metadata["persistedOnly"]?.stringValue == "yes")
    #expect(request.metadata["turnOnly"]?.stringValue == "yes")
}
