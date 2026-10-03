internal import NativeAgentMemoryProjection
import NativeAgentDomain
import Foundation
import LanguageModelRuntime

public struct MemoryGenerationMessage: Sendable, Equatable {
  public let role: String
  public let content: String

  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }
}

public protocol MemoryConsolidationProvider: Sendable {
  func generateMemoryText(system: String, messages: [MemoryGenerationMessage]) async throws
    -> String
}

public struct ModelRuntimeMemoryConsolidationProvider: MemoryConsolidationProvider {
  public let modelRuntime: ModelRuntime
  public let sessionID: String

  public init(
    modelRuntime: ModelRuntime,
    sessionID: String = "native-agent-memory"
  ) {
    self.modelRuntime = modelRuntime
    self.sessionID = sessionID
  }

  public func generateMemoryText(system: String, messages: [MemoryGenerationMessage])
    async throws -> String
  {
    var nativeAgentMessages: [AgentMessage] = []
    if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      nativeAgentMessages.append(AgentMessage(role: .system, content: system))
    }
    nativeAgentMessages.append(
      contentsOf: messages.map { message in
        AgentMessage(
          role: AgentMessage.Role(rawValue: message.role) ?? .user,
          content: message.content
        )
      }
    )
    let turn = try await modelRuntime.generate(
      ModelRequest(
        sessionID: sessionID,
        modelID: modelRuntime.modelDescriptor.id,
        messages: nativeAgentMessages,
        tools: [],
        metadata: [
          "native-agent.memory.consolidation": .bool(true),
          "native-agent.memory.disabled": .bool(true),
        ],
        outputFormat: modelRuntime.modelDescriptor.capabilities.contains(.structuredOutput)
          ? .jsonObject(schema: Self.outputSchema) : .text
      )
    )
    return turn.content
  }
  private static var outputSchema: JSONValue {
    let text: JSONValue = .object(["type": "string", "minLength": 1])
    let evidence: JSONValue = .object(["type": "object", "properties": .object([
      "event_id": text, "quote": text
    ]), "required": .array(["event_id", "quote"]), "additionalProperties": false])
    let record: JSONValue = .object(["type": "object", "properties": .object([
      "local_id": text,
      "kind": .object(["type": "string", "enum": .array(["fact", "episode", "instruction", "workflow", "gotcha"])]),
      "slot_key": .object(["type": .array(["string", "null"])]),
      "content": text,
      "valid_from_ms": .object(["type": .array(["integer", "null"])]),
      "evidence": .object(["type": "array", "minItems": 1, "maxItems": 16, "items": evidence])
    ]), "required": .array(["local_id", "kind", "slot_key", "content", "valid_from_ms", "evidence"]), "additionalProperties": false])
    let relation: JSONValue = .object(["type": "object", "properties": .object([
      "from": text, "to": text,
      "relation": .object(["type": "string", "enum": .array(["supersedes", "causes", "depends_on"])])
    ]), "required": .array(["from", "relation", "to"]), "additionalProperties": false])
    return .object(["type": "object", "properties": .object([
      "closed_through_event_id": .object(["type": .array(["string", "null"])]),
      "records": .object(["type": "array", "maxItems": 16, "items": record]),
      "relations": .object(["type": "array", "maxItems": 24, "items": relation])
    ]), "required": .array(["closed_through_event_id", "records", "relations"]), "additionalProperties": false])
  }
}
