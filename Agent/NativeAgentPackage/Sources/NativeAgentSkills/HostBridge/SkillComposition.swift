import Foundation
import NativeAgentDomain

public protocol SkillPromptSource: Sendable {
    func makeSystemPrompt(basePrompt: String) async throws -> String
}

public protocol SkillRuntimeClient: Sendable {
    func loadSkill(named skillName: String, callID: String) async throws -> ToolResult
    func readSkillFile(
        skillName: String,
        relativePath: String,
        characterOffset: Int,
        maxCharacters: Int,
        callID: String
    ) async throws -> ToolResult
    func runJS(
        skillName: String,
        scriptName: String,
        dataJSONString: String,
        callID: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult
    func runIntent(
        intent: String,
        parametersJSON: String,
        callID: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult
}

extension SkillLibrary: SkillPromptSource {}

public struct SkillsPromptAugmentor: PromptAugmentor {
    private let source: any SkillPromptSource

    public init(source: any SkillPromptSource) {
        self.source = source
    }

    public func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
        let basePrompt = request.normalizedBasePrompt
        let prompt = try await source.makeSystemPrompt(basePrompt: basePrompt)
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct SkillToolPack: ToolPack {
    public let packID = "toolpack.skills"
    private let runtime: any SkillRuntimeClient

    package static var recoveryDefinitions: [ToolDefinition] {
        [loadSkillDefinition, readSkillFileDefinition, runJSDefinition, runIntentDefinition]
    }

    public init(runtime: any SkillRuntimeClient) {
        self.runtime = runtime
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: Self.loadSkillDefinition) { call, _ in
                let arguments = try SkillLoadToolCallArguments(call.arguments)
                return try await runtime.loadSkill(
                    named: arguments.skillName,
                    callID: call.id
                )
            },
            ClosureToolExecutor(definition: Self.readSkillFileDefinition) { call, _ in
                let arguments = try SkillReadFileToolCallArguments(call.arguments)
                return try await runtime.readSkillFile(
                    skillName: arguments.skillName,
                    relativePath: arguments.relativePath,
                    characterOffset: arguments.characterOffset,
                    maxCharacters: arguments.maxCharacters,
                    callID: call.id
                )
            },
            ClosureToolExecutor(definition: Self.runJSDefinition) { call, context in
                let arguments = try SkillRunJSToolCallArguments(call.arguments)
                return try await runtime.runJS(
                    skillName: arguments.skillName,
                    scriptName: arguments.scriptName,
                    dataJSONString: arguments.dataJSONString,
                    callID: call.id,
                    context: context
                )
            },
            ClosureToolExecutor(definition: Self.runIntentDefinition) { call, context in
                let arguments = try SkillRunIntentToolCallArguments(call.arguments)
                return try await runtime.runIntent(
                    intent: arguments.intent,
                    parametersJSON: arguments.parametersJSON,
                    callID: call.id,
                    context: context
                )
            }
        ]
    }

    private static var loadSkillDefinition: ToolDefinition {
        ToolDefinition(
            name: "load_skill",
            description: "Load a selected skill and return the exact SKILL.md instructions so the model can follow them before the next call.",
            capabilityID: .skills,
            inputSchema: ToolSchema.object(
                properties: [
                    "skill_name": ToolSchema.string(description: "The exact skill name to load.", minLength: 1)
                ],
                required: ["skill_name"]
            ),
            approvalPolicy: .automatic,
            effect: .readOnly
        )
    }

    private static var readSkillFileDefinition: ToolDefinition {
        ToolDefinition(
            name: "read_skill_file",
            description: "Read a text supporting file from a selected Skill's immutable execution snapshot. Continue with nextCharacterOffset when truncated.",
            capabilityID: .skills,
            inputSchema: ToolSchema.object(
                properties: [
                    "skill_name": ToolSchema.string(description: "Exact selected Skill name.", minLength: 1),
                    "path": ToolSchema.string(description: "Supporting-file path returned by load_skill, such as references/guide.md.", minLength: 1, maxLength: 1_024),
                    "character_offset": ToolSchema.integer(description: "Character offset to start from. Defaults to 0.", minimum: 0),
                    "max_characters": ToolSchema.integer(description: "Maximum characters to return. Defaults to \(SkillSupportingFileRead.defaultCharactersPerRead).", minimum: 1, maximum: SkillSupportingFileRead.maximumCharactersPerRead),
                ],
                required: ["skill_name", "path"]
            ),
            approvalPolicy: .automatic,
            effect: .readOnly
        )
    }

    private static var runJSDefinition: ToolDefinition {
        ToolDefinition(
            name: "run_js",
            description: "Run an HTML or JS-backed skill script. Use 'index.html' when the skill instructions do not specify a different script.",
            capabilityID: .skills,
            inputSchema: ToolSchema.object(
                properties: [
                    "skill_name": ToolSchema.string(description: "The name of the loaded skill.", minLength: 1),
                    "script_name": ToolSchema.string(description: "The script entrypoint, such as index.html or get_genres.html.", minLength: 1),
                    "data": SkillJSONPayloadSupport.anyJSONSchema(
                        description: "A JSON payload for the skill. You may pass a JSON object directly or a JSON string. Use {} when no payload is required."
                    )
                ],
                required: ["skill_name", "script_name"]
            ),
            approvalPolicy: .automatic,
            effect: .readOnly
        )
    }

    private static var runIntentDefinition: ToolDefinition {
        ToolDefinition(
            name: "run_intent",
            description: "Execute a skill-owned native intent surface. This is for explicit app actions that can mutate state or leave the chat context.",
            capabilityID: .skills,
            inputSchema: ToolSchema.object(
                properties: [
                    "intent": ToolSchema.string(description: "The exact intent name.", minLength: 1),
                    "parameters": SkillJSONPayloadSupport.objectOrJSONStringSchema(
                        description: "A JSON object or JSON string containing the intent parameters. Use {} when no parameters are required."
                    )
                ],
                required: ["intent"]
            ),
            approvalPolicy: .requireApproval,
            effect: .mutation
        )
    }
}
