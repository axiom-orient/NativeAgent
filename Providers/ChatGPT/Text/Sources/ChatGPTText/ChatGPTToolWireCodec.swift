import Foundation
import LanguageModelCore

enum ChatGPTToolWireCodec {
  // Reserve the prefix so an authored identifier cannot impersonate an encoded one.
  // Stable hashing also keeps long and Unicode canonical names within the wire limit.
  static func wireName(_ name: String) -> String {
    if !name.hasPrefix("na_"), (1...64).contains(name.utf8.count),
      name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
        || (48...57).contains($0) || $0 == 45 || $0 == 95 }) { return name }
    return "na_" + SHA256HexDigest.digest(name).prefix(61)
  }

  static func canonicalCall(_ call: ToolCall, tools: [ModelTool]) throws -> ToolCall {
    let matches = tools.filter { wireName($0.name) == call.name }
    guard matches.count == 1, let tool = matches.first else {
      throw ModelGenerationFailure(.malformedEvent, "Provider returned an unknown function name.")
    }
    return ToolCall(id: call.id, name: tool.name, arguments: call.arguments, metadata: call.metadata)
  }

  static func inputItems(for messages: [AgentMessage]) throws -> [[String: Any]] {
    var items: [[String: Any]] = []
    for message in messages {
      switch message.role {
      case .system, .user:
        guard message.toolCalls.isEmpty, message.toolCallID == nil else {
          throw ModelGenerationFailure(.invalidRequest, "Tool state is invalid for a non-tool message.")
        }
        items.append(["role": role(message.role), "content": message.content])

      case .assistant:
        if !message.content.isEmpty {
          items.append(["role": "assistant", "content": message.content])
        }
        for call in message.toolCalls {
          items.append(try functionCallItem(call))
        }

      case .tool:
        guard let callID = message.toolCallID, !callID.isEmpty, message.toolCalls.isEmpty else {
          throw ModelGenerationFailure(.invalidRequest, "Tool messages require exactly one tool call identifier.")
        }
        items.append([
          "type": "function_call_output",
          "call_id": callID,
          "output": try message.modelVisibleContent(),
        ])
      }
    }
    return items
  }

  static func tools(_ tools: [ModelTool]) throws -> [[String: Any]] {
    guard Set(tools.map { wireName($0.name) }).count == tools.count else {
      throw ModelGenerationFailure(.invalidRequest, "Function tool wire names must be unique.")
    }
    return try tools.map { tool in
      [
        "type": "function",
        "name": wireName(tool.name),
        "description": tool.description,
        "strict": false,
        "parameters": try foundationObject(tool.inputSchema),
      ]
    }
  }

  static func functionCall(from item: [String: Any]) throws -> ToolCall {
    guard chatGPTString(item, "type") == "function_call",
      let callID = chatGPTString(item, "call_id"), !callID.isEmpty,
      let name = chatGPTString(item, "name"), !name.isEmpty,
      let argumentsString = chatGPTString(item, "arguments")
    else {
      throw ChatGPTWireError.malformedSSE
    }
    guard argumentsString.utf8.count <= 1_048_576 else {
      throw ChatGPTWireError.responseTooLarge
    }
    let data = Data(argumentsString.utf8)
    let any: Any
    do {
      any = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ChatGPTWireError.malformedSSE
    }
    guard let object = any as? [String: Any], let arguments = JSONValue.from(any: object) else {
      throw ChatGPTWireError.malformedSSE
    }
    return ToolCall(id: callID, name: name, arguments: arguments)
  }

  private static func functionCallItem(_ call: ToolCall) throws -> [String: Any] {
    let arguments = try foundationObject(call.arguments)
    let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
    guard let string = String(data: data, encoding: .utf8) else {
      throw ModelGenerationFailure(.invalidRequest, "Tool call arguments are not valid UTF-8 JSON.")
    }
    return [
      "type": "function_call",
      "call_id": call.id,
      "name": wireName(call.name),
      "arguments": string,
    ]
  }

  private static func foundationObject(_ value: JSONValue) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ModelGenerationFailure(.invalidRequest, "Function tool schema and arguments must be JSON objects.")
    }
    return object
  }

  private static func role(_ role: AgentMessage.Role) -> String {
    switch role {
    case .system: "system"
    case .user: "user"
    case .assistant: "assistant"
    case .tool: "tool"
    }
  }
}
