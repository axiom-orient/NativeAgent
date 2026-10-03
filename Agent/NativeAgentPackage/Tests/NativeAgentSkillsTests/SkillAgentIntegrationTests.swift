import Foundation
import Testing
import NativeAgent
import NativeAgentDomain
import NativeAgentSkills
import NativeAgentTestSupport

@Suite(.serialized)
struct SkillAgentIntegrationTests {
    @Test
    func agentReceivesSkillCatalogAndSkillToolsThroughHighLevelFacade() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgent-SkillAgentIntegration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let integration = SkillAgentIntegration(
            promptSource: FixedSkillPromptSource(),
            runtime: RecordingSkillRuntime()
        )
        let model = ScriptedModelClient(scriptedTurns: [
            ModelTurn(content: "ready")
        ])
        let agent = try Agent(
            model: model,
            storage: .directory(root),
            instructions: "Base agent instruction.",
            capabilities: [integration]
        )

        let result = try await agent.run("Use an appropriate skill.")
        let request = try #require(await model.recordedRequests().first)
        let systemPrompt = try #require(
            request.messages.first(where: { $0.role == .system })?.content
        )

        #expect(result.status == .completed)
        #expect(systemPrompt.contains("Base agent instruction."))
        #expect(systemPrompt.contains("Available skills: deterministic-demo"))
        #expect(Set(request.tools.map(\.name)) == Set(["load_skill", "read_skill_file", "run_js", "run_intent"]))
    }
}

private struct FixedSkillPromptSource: SkillPromptSource {
    func makeSystemPrompt(basePrompt: String) async throws -> String {
        [basePrompt, "Available skills: deterministic-demo"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

private struct RecordingSkillRuntime: SkillRuntimeClient {
    func loadSkill(named skillName: String, callID: String) async throws -> ToolResult {
        .text(callID: callID, toolName: "load_skill", content: skillName)
    }

    func readSkillFile(
        skillName: String,
        relativePath: String,
        characterOffset: Int,
        maxCharacters: Int,
        callID: String
    ) async throws -> ToolResult {
        .text(
            callID: callID,
            toolName: "read_skill_file",
            content: "read \(skillName):\(relativePath):\(characterOffset):\(maxCharacters)"
        )
    }

    func runJS(
        skillName: String,
        scriptName: String,
        dataJSONString: String,
        callID: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        .text(callID: callID, toolName: "run_js", content: dataJSONString)
    }

    func runIntent(
        intent: String,
        parametersJSON: String,
        callID: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        .text(callID: callID, toolName: "run_intent", content: parametersJSON)
    }
}
