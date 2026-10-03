import Foundation
import LanguageModelCore
import LanguageModelRuntime
import Testing

@testable import LiteRTProvider

@Suite("LiteRT public contract")
struct LiteRTContractTests {
  @Test func modelToolSupportRequiresExplicitArtifactQualification() async throws {
    let plain = try LiteRTTextModel(id: "plain", modelURL: URL(fileURLWithPath: "/tmp/plain.litertlm"), sampling: .greedy)
    let qualified = try LiteRTTextModel(id: "tools", modelURL: URL(fileURLWithPath: "/tmp/tools.litertlm"), supportsToolCalls: true)
    #expect(!plain.capabilities.contains(.toolCalls))
    #expect(qualified.capabilities.contains(.toolCalls))
    let connector = try LiteRTProviderConnector(models: [plain, qualified], defaultModelID: "plain")
    let descriptors = try await connector.models()
    #expect(descriptors.first { $0.id == "plain" }?.capabilities == plain.capabilities)
    #expect(descriptors.first { $0.id == "tools" }?.capabilities == qualified.capabilities)
  }

  @Test func modelRequiresLocalFileURLs() throws {
    #expect(throws: ModelGenerationFailure.self) {
      _ = try LiteRTTextModel(
        id: "model",
        modelURL: URL(string: "https://example.com/model.litertlm")!
      )
    }
  }

  @Test func capabilitiesDescribeImplementedSemanticSurfaceOnly() {
    #expect(LiteRTProvider.capabilities.contains(.textInput))
    #expect(LiteRTProvider.capabilities.contains(.textOutput))
    #expect(LiteRTProvider.capabilities.contains(.toolCalls))
    #expect(LiteRTProvider.capabilities.contains(.structuredOutput))
    #expect(!LiteRTProvider.capabilities.contains(.streaming))
    #expect(!LiteRTProvider.capabilities.contains(.imageInput))
    #expect(!LiteRTProvider.capabilities.contains(.audioInput))
  }

  @Test func requestRendererKeepsSystemAndCurrentMessageSeparated() throws {
    let request = ModelRequest(
      sessionID: "session",
      messages: [
        AgentMessage(role: .system, content: "system rules"),
        AgentMessage(role: .user, content: "hello"),
      ],
      tools: []
    )

    let rendered = try LiteRTRequestRenderer.render(request)
    #expect(rendered.initialMessages == nil)
    #expect(rendered.tools == nil)
    #expect(rendered.outputSchema == nil)

    let system = try #require(rendered.systemContents)
    let systemJSON = try #require(
      JSONSerialization.jsonObject(with: Data(system.utf8)) as? [[String: Any]]
    )
    #expect(systemJSON.count == 1)
    #expect(systemJSON[0]["type"] as? String == "text")
    #expect(systemJSON[0]["text"] as? String == "system rules")

    let currentJSON = try #require(
      JSONSerialization.jsonObject(with: Data(rendered.currentMessage.utf8)) as? [String: Any]
    )
    #expect(currentJSON["role"] as? String == "user")
  }

  @Test func requestRendererMapsToolsAndNativeJSONConstraint() throws {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object(["answer": .object(["type": .string("string")])]),
      "required": .array([.string("answer")]),
    ])
    let request = ModelRequest(
      sessionID: "session",
      messages: [AgentMessage(role: .user, content: "hello")],
      tools: [],
      requiredCapabilities: [.textInput, .textOutput, .structuredOutput],
      outputFormat: .jsonObject(schema: schema)
    )

    let rendered = try LiteRTRequestRenderer.render(request)
    let renderedSchema = try #require(rendered.outputSchema)
    let decoded = try #require(
      JSONSerialization.jsonObject(with: Data(renderedSchema.utf8)) as? [String: Any]
    )
    #expect(decoded["type"] as? String == "object")
    #expect((decoded["required"] as? [String]) == ["answer"])

    let toolRequest = ModelRequest(
      sessionID: "session",
      messages: [AgentMessage(role: .user, content: "weather")],
      tools: [
        ModelTool(
          name: "weather",
          description: "Get weather",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")])]),
          ])
        )
      ],
      requiredCapabilities: [.textInput, .textOutput, .toolCalls]
    )
    let renderedTool = try LiteRTRequestRenderer.render(toolRequest)
    let tools = try #require(renderedTool.tools)
    let toolJSON = try #require(
      JSONSerialization.jsonObject(with: Data(tools.utf8)) as? [[String: Any]]
    )
    let function = try #require(toolJSON.first?["function"] as? [String: Any])
    #expect(function["name"] as? String == "weather")
  }

  @Test func requestRendererPreservesStructuredToolObservation() throws {
    let call = ToolCall(id: "call-1", name: "files.readText", arguments: ["path": "value.txt"])
    let request = ModelRequest(
      sessionID: "session",
      messages: [
        AgentMessage(role: .user, content: "read"),
        AgentMessage(role: .assistant, content: "", toolCalls: [call]),
        AgentMessage(
          role: .tool,
          content: "hello",
          toolCallID: call.id,
          toolName: call.name,
          metadata: [
            "output": .object(["content": .string("hello"), "sha256": .string("sha-1")]),
            "isError": .bool(false),
            "artifacts": .array([]),
            "byteCount": .integer(5)
          ]
        ),
        AgentMessage(role: .user, content: "continue")
      ],
      tools: [
        ModelTool(
          name: call.name,
          description: "read",
          inputSchema: .object(["type": .string("object")])
        )
      ],
      requiredCapabilities: [.textInput, .textOutput, .toolCalls]
    )

    let rendered = try LiteRTRequestRenderer.render(request)
    let initialString = try #require(rendered.initialMessages)
    let initial = try #require(
      JSONSerialization.jsonObject(with: Data(initialString.utf8)) as? [[String: Any]]
    )
    let tool = try #require(initial.first { $0["role"] as? String == "tool" })
    let content = try #require(tool["content"] as? [[String: Any]])
    let response = try #require(content.first?["response"] as? String)
    let observation = try #require(
      JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
    )
    let output = try #require(observation["output"] as? [String: Any])
    let metadata = try #require(observation["metadata"] as? [String: Any])
    #expect(output["sha256"] as? String == "sha-1")
    #expect(metadata["byteCount"] as? Int == 5)
    #expect(observation["isError"] as? Bool == false)
  }

  @Test func responseParserPreservesTextAndToolCalls() throws {
    let textTurn = try LiteRTResponseParser.parse(
      #"{"role":"model","content":[{"type":"text","text":"hello"}]}"#
    )
    #expect(textTurn.content == "hello")
    #expect(textTurn.toolCalls.isEmpty)
    #expect(textTurn.stopReason == .stop)

    let toolTurn = try LiteRTResponseParser.parse(
      #"{"role":"model","tool_calls":[{"id":"call-1","type":"function","function":{"name":"weather","arguments":{"city":"Seoul"}}}]}"#
    )
    #expect(toolTurn.content.isEmpty)
    #expect(toolTurn.toolCalls.count == 1)
    #expect(toolTurn.toolCalls[0].id == "call-1")
    #expect(toolTurn.toolCalls[0].name == "weather")
    #expect(toolTurn.toolCalls[0].arguments == .object(["city": .string("Seoul")]))
    #expect(toolTurn.stopReason == .toolUse)
  }

  @Test func connectorDoesNotReportReadyWithoutNativeBackend() async throws {
    #if !canImport(CLiteRTLM) && !canImport(CLiteRTLM_mac)
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("litert-readiness-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      try Data("placeholder".utf8).write(to: root)
      let model = try LiteRTTextModel(id: "model", modelURL: root)
      let connector = try LiteRTProviderConnector(models: [model])
      let availability = try await connector.availability()
      switch availability {
      case .unavailable(let reason):
        #expect(!reason.isEmpty)
      case .available, .authenticationRequired:
        Issue.record("A build without CLiteRTLM must never report LiteRT ready.")
      }
    #endif
  }

}
