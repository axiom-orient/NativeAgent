import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentStore
import NativeAgentTestSupport

@Test
func startSessionUsesPromptAugmentorOutputAsSystemPrompt() async throws {
    struct RecordingPromptAugmentor: PromptAugmentor {
        let expectedToolCount: Int

        func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
            #expect(request.basePrompt == "Base system prompt")
            #expect(request.userPrompt == "hello")
            #expect(request.availableTools.count == expectedToolCount)
            return "Augmented system prompt"
        }
    }

    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ApplicationSupportSessionStore(rootURL: tempRoot)
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "ok")
    ])

    let coordinator = try SessionCoordinator(
        modelClient: provider,
        approvalRouter: AllowAllApprovalRouter(),
        runtimeStore: store,
        toolPacks: [],
        promptAugmentor: RecordingPromptAugmentor(expectedToolCount: 0)
    )

    let snapshot = try await coordinator.startSession(
        userPrompt: "hello",
        systemPrompt: "Base system prompt"
    )

    #expect(snapshot.messages.first?.role == .system)
    #expect(snapshot.messages.first?.content == "Augmented system prompt")
}
