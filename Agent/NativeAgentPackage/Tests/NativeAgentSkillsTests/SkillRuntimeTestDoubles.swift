import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct FakePromptSource: SkillPromptSource {
    func makeSystemPrompt(basePrompt: String) async throws -> String {
        [basePrompt, "skills"].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct FakeSkillRuntime: SkillRuntimeClient {
    func loadSkill(named skillName: String, callID: String) async throws -> ToolResult {
        .text(callID: callID, toolName: "load_skill", content: "loaded \(skillName)")
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
        .text(
            callID: callID, toolName: "run_js",
            content: "ran \(skillName):\(scriptName):\(dataJSONString)")
    }

    func runIntent(
        intent: String,
        parametersJSON: String,
        callID: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        .text(callID: callID, toolName: "run_intent", content: "intent \(intent):\(parametersJSON)")
    }
}



actor RecordingScriptRunner: SkillScriptRunner {
    struct Invocation: Sendable {
        let skillName: String
        let scriptURL: URL
        let readAccessURL: URL?
        let inputJSON: String
        let secret: String?
    }

    private let response: SkillScriptResponse
    private var invocations: [Invocation] = []

    init(response: SkillScriptResponse) {
        self.response = response
    }

    func run(
        skill: ManagedSkill,
        scriptURL: URL,
        readAccessURL: URL?,
        inputJSON: String,
        secret: String?,
        context _: ToolExecutionContext
    ) async throws -> SkillScriptResponse {
        invocations.append(
            Invocation(
                skillName: skill.name,
                scriptURL: scriptURL,
                readAccessURL: readAccessURL,
                inputJSON: inputJSON,
                secret: secret
            )
        )
        return response
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }
}

actor ThrowingScriptRunner: SkillScriptRunner {
    private let error: any Error
    private(set) var invocationCount = 0

    init(error: any Error) {
        self.error = error
    }

    func run(
        skill _: ManagedSkill,
        scriptURL _: URL,
        readAccessURL _: URL?,
        inputJSON _: String,
        secret _: String?,
        context _: ToolExecutionContext
    ) async throws -> SkillScriptResponse {
        invocationCount += 1
        throw error
    }
}

struct NoopIntentService: SkillIntentService {
    func execute(
        intent: String,
        parametersJSON: String,
        context _: ToolExecutionContext
    ) async throws -> ToolResult {
        .text(callID: "intent-call", toolName: intent, content: parametersJSON)
    }
}


func noopContext() -> ToolExecutionContext {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    return ToolExecutionContext(
        sessionID: "session",
        sessionDirectoryURL: root,
        sandboxRootURL: root
    )
}


struct ArtifactProducingIntentService: SkillIntentService {
    func toolDefinition(for intent: String) async -> ToolDefinition? {
        ToolDefinition(
            name: intent,
            description: "Persist a read-only bridge artifact for tests.",
            capabilityID: .skills,
            inputSchema: ToolSchema.object(properties: [:], additionalProperties: true),
            approvalPolicy: .automatic,
            effect: .readOnly
        )
    }

    func execute(
        intent: String,
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        .text(
            callID: "tool-call",
            toolName: intent,
            content: parametersJSON,
            artifacts: [
                ArtifactWriteRequest(
                    preferredFilename: "report.html",
                    mimeType: "text/html",
                    data: Data("<html>ok</html>".utf8),
                    metadata: ["preferredFilename": .string("report.html")]
                )
            ],
            metadata: ["intent": .string(intent)]
        )
    }
}
