import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test
func skillsPromptAugmentorUsesSkillPromptSource() async throws {
    let augmentor = SkillsPromptAugmentor(source: FakePromptSource())
    let prompt = try await augmentor.augmentSystemPrompt(
        PromptAugmentationRequest(sessionID: "session", basePrompt: "base", userPrompt: "hi")
    )

    #expect(prompt == "base\nskills")
}

@Test
func skillToolPackExposesCanonicalSkillTools() async throws {
    let toolPack = SkillToolPack(runtime: FakeSkillRuntime())
    let tools = toolPack.executors().map(\.definition).sorted { $0.name < $1.name }

    #expect(tools.map(\.name) == ["load_skill", "read_skill_file", "run_intent", "run_js"])
    #expect(Set(tools.map(\.capabilityID)) == [.skills])
}

@Test
func skillToolPackExecutesRuntimeThroughToolExecutor() async throws {
    let toolPack = SkillToolPack(runtime: FakeSkillRuntime())
    let executor = try #require(toolPack.executors().first { $0.definition.name == "run_js" })

    let result = try await executor.execute(
        call: ToolCall(
            id: "call-1",
            name: "run_js",
            arguments: [
                "skill_name": "charts",
                "script_name": "index.html",
                "data": "{}",
            ]
        ),
        context: noopContext()
    )

    #expect(result.toolName == "run_js")
    #expect(result.renderedContent == "ran charts:index.html:{}")
}
