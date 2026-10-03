import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

@Test
func parserAcceptsBlockListMetadata() throws {
  let markdown = """
  ---
  name: image-transparent-asset
  description: Transparent skill
  metadata:
    requires-network: true
    allowed-domains:
      - openai.com
      - api.openai.com
    host-intents:
      - chatgpt.images.generate
    bridge-intents:
      - local.preview
    default-selected: false
  ---

  Use the installed image intent.
  """

  let skill = try SkillMarkdownParser.parse(
    markdown,
    builtIn: false,
    selected: false,
    group: "custom",
    relativePath: "image-transparent-asset/SKILL.md",
    source: ManagedSkillSource(kind: .imported, location: "tests")
  )

  #expect(skill.name == "image-transparent-asset")
  #expect(skill.capabilityRequirements.requiresNetwork)
  #expect(skill.capabilityRequirements.allowedDomains == ["openai.com", "api.openai.com"])
  #expect(skill.capabilityRequirements.hostIntents == ["chatgpt.images.generate"])
  #expect(skill.capabilityRequirements.bridgeIntents == ["local.preview"])
  #expect(skill.defaultSelected == false)
}

@Test
func parserAcceptsTopLevelMetadataFieldsWithoutMetadataBlock() throws {
  let markdown = """
  ---
  name: plain-skill
  description: Plain skill
  requires-network: true
  default-selected: true
  ---

  Use this skill.
  """

  let skill = try SkillMarkdownParser.parse(
    markdown,
    builtIn: false,
    selected: true,
    group: "custom",
    relativePath: "plain-skill/SKILL.md",
    source: ManagedSkillSource(kind: .imported, location: "tests")
  )

  #expect(skill.capabilityRequirements.requiresNetwork)
  #expect(skill.defaultSelected == true)
}

@Test
func runIntentValidatesSpecificHandlerSchemaBeforeExecution() async throws {
  let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let runtime = SkillRuntime(
    library: SkillLibrary(
      workspace: .init(
        supportRootURL: workspaceRoot.appendingPathComponent("Support", isDirectory: true),
        userSkillsRootURL: workspaceRoot.appendingPathComponent("Documents/Skills", isDirectory: true)
      )
    ),
    scriptRunner: RecordingScriptRunner(response: SkillScriptResponse(result: "ok")),
    intentService: StructuredIntentService()
  )

  await #expect(throws: AgentError.self) {
    _ = try await runtime.runIntent(
      intent: "demo.intent",
      parametersJSON: "{\"kind\":\"bad\"}",
      callID: "call-1",
      context: noopContext()
    )
  }

  let result = try await runtime.runIntent(
    intent: "demo.intent",
    parametersJSON: "{\"kind\":\"ok\",\"count\":2}",
    callID: "call-2",
    context: noopContext()
  )
  #expect(result.metadata["intentName"]?.stringValue == "demo.intent")
  #expect(result.metadata["intentEffect"]?.stringValue == ToolEffectKind.mutation.rawValue)
  #expect(result.renderedContent.contains("\"kind\":\"ok\""))
}

private struct StructuredIntentService: SkillIntentService {
  func toolDefinition(for intent: String) async -> ToolDefinition? {
    ToolDefinition(
      name: intent,
      description: "Structured test intent",
      capabilityID: .skills,
      inputSchema: ToolSchema.object(
        properties: [
          "kind": ToolSchema.string(description: "kind", enum: ["ok"]),
          "count": ToolSchema.integer(description: "count", minimum: 1, maximum: 3),
        ],
        required: ["kind"],
        additionalProperties: false
      ),
      approvalPolicy: .requireApproval,
      effect: .mutation
    )
  }

  func execute(intent: String, parametersJSON: String, context: ToolExecutionContext) async throws -> ToolResult {
    .text(callID: "structured", toolName: intent, content: parametersJSON)
  }
}

@Test
func customSkillRoundTripsCapabilityRequirementsIntoSkillMarkdown() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = SkillLibrary(
    workspace: .init(
      supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
      userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
  )
  let requirements = SkillCapabilityRequirements(
    requiresNetwork: true,
    allowedDomains: ["chatgpt.com"],
    hostIntents: ["chatgpt.images.effect.sticker-cutout"]
  )
  let result = try await library.upsertCustomTextSkill(
    name: "image-sticker-cutout",
    description: "Sticker image effect",
    instructions: "Call the declared host intent.",
    requiresSecret: false,
    requiresSecretDescription: "",
    homepage: "",
    capabilityRequirements: requirements,
    defaultSelected: true,
    selected: true
  )
  let directory = try await library.skillDirectoryURL(for: result.skill)
  let markdown = try String(contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
  let reloaded = try #require((try await library.snapshot()).skills.first { $0.name == "image-sticker-cutout" })

  #expect(markdown.contains("requires-network: true"))
  #expect(markdown.contains("- chatgpt.com"))
  #expect(markdown.contains("- chatgpt.images.effect.sticker-cutout"))
  #expect(markdown.contains("default-selected: true"))
  #expect(reloaded.capabilityRequirements == requirements)
  #expect(reloaded.defaultSelected == true)
}

@Test
func runIntentRequiresSelectedSkillAuthorizationWhenDeclaredByHandler() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = SkillLibrary(
    workspace: .init(
      supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
      userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
  )
  let service = SelectedSkillIntentService()
  let runtime = SkillRuntime(
    library: library,
    scriptRunner: RecordingScriptRunner(response: SkillScriptResponse(result: "ok")),
    intentService: service
  )

  await #expect(throws: AgentError.self) {
    _ = try await runtime.runIntent(
      intent: SelectedSkillIntentService.intent,
      parametersJSON: "{}",
      callID: "blocked",
      context: noopContext()
    )
  }

  _ = try await library.upsertCustomTextSkill(
    name: "authorized-image-skill",
    description: "Authorizes one image effect",
    instructions: "Use the declared host intent.",
    requiresSecret: false,
    requiresSecretDescription: "",
    homepage: "",
    capabilityRequirements: SkillCapabilityRequirements(hostIntents: [SelectedSkillIntentService.intent]),
    defaultSelected: true,
    selected: true
  )

  let allowed = try await runtime.runIntent(
    intent: SelectedSkillIntentService.intent,
    parametersJSON: "{}",
    callID: "allowed",
    context: noopContext()
  )
  #expect(allowed.metadata["intentName"]?.stringValue == SelectedSkillIntentService.intent)
}

private struct SelectedSkillIntentService: SkillIntentService {
  static let intent = "chatgpt.images.effect.test"

  func toolDefinition(for intent: String) async -> ToolDefinition? {
    ToolDefinition(
      name: intent,
      description: "Selected-skill bound intent",
      capabilityID: .images,
      inputSchema: ToolSchema.object(properties: [:], additionalProperties: false),
      approvalPolicy: .requireApproval,
      effect: .mutation,
      metadata: ["requiresSelectedSkill": .bool(true)]
    )
  }

  func execute(intent: String, parametersJSON: String, context: ToolExecutionContext) async throws -> ToolResult {
    .text(callID: "intent", toolName: intent, content: parametersJSON)
  }
}
