// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Parts of this implementation were originally authored by @john-rocky and
// ported from https://github.com/john-rocky/swift-litert-lm/tree/main.

#if canImport(FoundationModels) && compiler(>=6.4)

  import Foundation
  import FoundationModels
  @preconcurrency import LiteRTLM

  struct LiteRTTranscriptPlan {
    let systemMessage: Message?
    let history: [Message]
    let prompt: Message
  }

  enum LiteRTTranscriptPlanner {
    static func make(
      from transcript: Transcript,
      schemaJSON: String?,
      tools: [Transcript.ToolDefinition]
    ) throws -> LiteRTTranscriptPlan {
      let entries = Array(transcript)
      guard
        let triggerIndex = entries.lastIndex(where: {
          switch $0 {
          case .prompt, .toolOutput: return true
          default: return false
          }
        })
      else {
        throw LiteRTFMError.noPrompt
      }

      var systemText: [String] = []
      if !tools.isEmpty { systemText.append(try toolInstructions(tools)) }
      var history: [Message] = []
      var trigger: Message?

      for (index, entry) in entries.enumerated() {
        let isTrigger = index == triggerIndex
        switch entry {
        case .instructions(let instructions):
          systemText.append(try text(of: instructions.segments))
        case .prompt(let prompt):
          var contents = try contents(of: prompt.segments)
          if isTrigger, let schemaJSON, !schemaJSON.isEmpty {
            contents.append(
              .text(
                "\n\nRespond with ONLY a JSON object that conforms to this JSON schema. "
                  + "Output valid JSON and nothing else:\n\(schemaJSON)"))
          }
          let message = Message(contents: contents, role: .user)
          if isTrigger { trigger = message } else { history.append(message) }
        case .response(let response):
          history.append(Message(contents: [.text(try text(of: response.segments))], role: .model))
        case .toolOutput(let output):
          let result = try text(of: output.segments)
          let message = Message(
            contents: [.toolResponse(name: output.toolName, response: result, id: output.id)],
            role: .tool)
          if isTrigger { trigger = message } else { history.append(message) }
        case .toolCalls(let calls):
          let nativeCalls = try calls.map { call -> LiteRTLM.ToolCall in
            guard
              let arguments = try JSONSerialization.jsonObject(
                with: Data(call.arguments.jsonString.utf8)) as? [String: Any]
            else {
              throw LiteRTFMError.invalidToolCall("Historical tool arguments must be an object")
            }
            return LiteRTLM.ToolCall(name: call.toolName, id: call.id, arguments: arguments)
          }
          guard !nativeCalls.isEmpty else {
            throw LiteRTFMError.invalidToolCall("Historical tool call group must not be empty")
          }
          history.append(Message(contents: [], role: .model, toolCalls: nativeCalls))
        case .reasoning:
          break
        @unknown default:
          throw LiteRTFMError.unsupported("Unsupported native transcript entry or sampling mode")
        }
      }

      guard let prompt = trigger else { throw LiteRTFMError.noPrompt }
      let system = systemText.joined(separator: "\n").trimmingCharacters(
        in: .whitespacesAndNewlines)
      return LiteRTTranscriptPlan(
        systemMessage: system.isEmpty ? nil : Message(system, role: .system),
        history: history,
        prompt: prompt)
    }

    private static func toolInstructions(_ tools: [Transcript.ToolDefinition]) throws -> String {
      var lines = ["You can call tools to help answer the user. Available tools:"]
      for tool in tools {
        let parameters = try encodeSchema(tool.parameters)
        lines.append("- \(tool.name): \(tool.description). arguments schema: \(parameters)")
      }
      lines.append(
        "To call a tool, reply with ONLY this JSON and nothing else: "
          + "{\"tool_call\": {\"name\": \"<tool name>\", \"arguments\": { ... }}}. "
          + "If no tool is needed, answer the user directly.")
      return lines.joined(separator: "\n")
    }

    private static func text(of segments: [Transcript.Segment]) throws -> String {
      try segments.map { segment in
        guard case .text(let text) = segment else {
          throw LiteRTFMError.unsupported(
            "LiteRT compatibility adapter only supports text transcript segments")
        }
        return text.content
      }.joined(separator: " ")
    }

    static func encodeSchema(_ schema: GenerationSchema) throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(schema)
      return String(data: data, encoding: .utf8) ?? ""
    }

    private static func contents(of segments: [Transcript.Segment]) throws -> [Content] {
      var output: [Content] = []
      for segment in segments {
        switch segment {
        case .text(let text):
          if !text.content.isEmpty { output.append(.text(text.content)) }
        case .attachment(let attachment):
          guard case .image(let image) = attachment.content else {
            throw LiteRTFMError.unsupported(
              "LiteRT compatibility adapter only supports image attachments")
          }
          guard let png = pngData(from: image.cgImage) else {
            throw LiteRTFMError.unsupported("Image attachment could not be encoded as PNG")
          }
          output.append(.imageData(png))
        case .structure:
          throw LiteRTFMError.unsupported(
            "LiteRT compatibility adapter does not support structured transcript segments")
        @unknown default:
          throw LiteRTFMError.unsupported("Unsupported Foundation Models transcript segment")
        }
      }
      return output.isEmpty ? [.text("")] : output
    }
  }

#endif
