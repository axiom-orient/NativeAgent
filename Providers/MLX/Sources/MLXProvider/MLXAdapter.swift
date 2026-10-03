import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import LanguageModelCore
import Tokenizers

private enum MLXLiveGenerationPolicy {
  static let memoryCacheBytes = 20 * 1_024 * 1_024
  static let minimumGenerationTokens = 16
  static let maximumGenerationTokens = 4_096
  static let outputBytesPerGenerationTokenEstimate = 2
  static let minimumProbability: Float = 0.0
  static let repetitionContextTokens = 64
  static let deterministicSeed: UInt64 = 42
}

private struct MLXTokenizerLoader: TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    MLXTokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
  }
}

private struct MLXTokenizerBridge: MLXLMCommon.Tokenizer {
  private let upstream: any Tokenizers.Tokenizer

  init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }

  func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
  func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
  var bosToken: String? { upstream.bosToken }
  var eosToken: String? { upstream.eosToken }
  var unknownToken: String? { upstream.unknownToken }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    do {
      return try upstream.applyChatTemplate(
        messages: messages,
        tools: tools,
        additionalContext: additionalContext)
    } catch Tokenizers.TokenizerError.missingChatTemplate {
      throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
  }
}

extension MLXSessionLoader {
  static let live = Self(
    load: { directory, specification in
      Memory.cacheLimit = MLXLiveGenerationPolicy.memoryCacheBytes
      let model = try await LLMModelFactory.shared.loadContainer(
        from: directory,
        using: MLXTokenizerLoader())
      if !specification.extraEOSTokens.isEmpty {
        await model.update { context in
          context.configuration.extraEOSTokens.formUnion(specification.extraEOSTokens)
        }
      }
      return MLXLiveSession(model: model, specification: specification)
    },
    clearCache: { Memory.clearCache() }
  )
}

private actor MLXLiveSession: MLXLoadedSession {
  private var model: ModelContainer?
  private let specification: MLXModelSpecification

  init(model: ModelContainer, specification: MLXModelSpecification) {
    self.model = model
    self.specification = specification
  }

  func generate(
    request: ModelRequest,
    emit: @escaping @Sendable (ModelEvent) -> Void
  ) async throws {
    guard let model else { throw MLXTextError.invalidRuntimeOutput }
    let chat = try MLXChatMapper.map(
      request: request, disablesThinking: specification.disablesThinking)
    let maxTokens = min(
      MLXLiveGenerationPolicy.maximumGenerationTokens,
      max(
        MLXLiveGenerationPolicy.minimumGenerationTokens,
        request.maxOutputBytes / MLXLiveGenerationPolicy.outputBytesPerGenerationTokenEstimate
      )
    )
    if MLXGuidedOutput.isEligible(request: request, sampling: specification.sampling) {
      try await MLXGuidedOutput.generate(model: model, request: request,
        specification: specification, maxTokens: maxTokens, emit: emit)
      return
    }
    let session = ChatSession(
      model,
      history: chat.history,
      generateParameters: GenerateParameters(
        maxTokens: maxTokens,
        temperature: specification.sampling.temperature,
        topP: specification.sampling.topP,
        topK: specification.sampling.topK,
        minP: MLXLiveGenerationPolicy.minimumProbability,
        repetitionPenalty: specification.sampling.repetitionPenalty,
        repetitionContextSize: MLXLiveGenerationPolicy.repetitionContextTokens,
        seed: MLXLiveGenerationPolicy.deterministicSeed),
      additionalContext: specification.disablesThinking ? ["enable_thinking": false] : [:],
      tools: request.tools.isEmpty ? nil : request.tools.map(MLXChatMapper.tool))

    var toolCalls: [LanguageModelCore.ToolCall] = []
    var terminal: ModelTurn?
    var toolOutputBytes = 0
    var outputBytes = 0
    var emittedBytes = Data()
    do {
      for try await event in session.streamDetails(to: [chat.current]) {
        try Task.checkCancellation()
        switch event {
        case .chunk(let chunk):
          for delta in try request.limits.boundedDeltas(for: chunk) {
            let (next, overflow) = outputBytes.addingReportingOverflow(delta.utf8.count)
            guard !overflow, next <= request.maxOutputBytes - toolOutputBytes else {
              throw ModelGenerationFailure(
                .limitExceeded, "MLX text output exceeds the byte limit.")
            }
            emittedBytes.append(contentsOf: delta.utf8)
            emit(.textDelta(delta))
            outputBytes = next
          }
        case .rejectedToolCall:
          throw ModelGenerationFailure(.malformedEvent, "MLX rejected malformed tool-call output.")
        case .toolCall(let nativeCall):
          guard request.tools.contains(where: { $0.name == nativeCall.function.name }) else {
            throw ModelGenerationFailure(.policyViolation, "MLX generated an unregistered tool call.")
          }
          let arguments = try JSONDecoder().decode(
            LanguageModelCore.JSONValue.self,
            from: JSONEncoder().encode(nativeCall.function.arguments))
          let call = LanguageModelCore.ToolCall(
            id: nativeCall.id ?? "mlx-" + UUID().uuidString.lowercased(),
            name: nativeCall.function.name, arguments: arguments)
          guard toolCalls.count < 32, !toolCalls.contains(where: { $0.id == call.id }) else {
            throw ModelGenerationFailure(.malformedEvent, "MLX generated too many or duplicate tool calls.")
          }
          toolCalls.append(call)
          // Keep tool arguments within the same caller-owned output budget.
          toolOutputBytes = try JSONEncoder().encode(toolCalls).count
          guard toolOutputBytes <= request.maxOutputBytes - outputBytes else {
            throw ModelGenerationFailure(.limitExceeded, "MLX tool output exceeds the byte limit.")
          }
        case .info(let info):
          guard terminal == nil else {
            throw ModelGenerationFailure(.duplicateTerminal, "MLX returned duplicate generation info.")
          }
          if info.stopReason == .cancelled { throw CancellationError() }
          if info.stopReason == .length && !toolCalls.isEmpty {
            throw ModelGenerationFailure(.limitExceeded, "MLX tool generation reached the token limit.")
          }
          let stop: ModelStopReason = info.stopReason == .length ? .maxTokens : .stop
          guard let input = Int(exactly: info.promptTokenCount),
            let generated = Int(exactly: info.generationTokenCount)
          else {
            throw ModelGenerationFailure(.malformedEvent, "MLX token usage is invalid.")
          }
          let (total, overflow) = input.addingReportingOverflow(generated)
          guard !overflow else {
            throw ModelGenerationFailure(.malformedEvent, "MLX token usage is invalid.")
          }
          let usage = ModelUsage(
            inputTokens: input, outputTokens: generated, totalTokens: total)
          emit(.usage(usage))
          terminal = ModelTurn(
                content: String(decoding: emittedBytes, as: UTF8.self),
                toolCalls: toolCalls,
                usage: usage,
                stopReason: toolCalls.isEmpty ? stop : .toolUse)
        }
      }
      await session.synchronize()
      try Task.checkCancellation()
      guard let terminal else {
        throw ModelGenerationFailure(.terminalMissing, "MLX generation returned no terminal info.")
      }
      try terminal.validateGenerationContract(for: request)
      if case .jsonObject(let schema) = request.outputFormat {
        try MLXOutputSchema.validateOutput(terminal.content, schema: schema)
      }
      emit(.completed(terminal))
    } catch {
      await session.synchronize()
      throw error
    }
  }

  func shutdown() async { model = nil }

}

enum MLXChatMapper {
  static func map(
    request: ModelRequest,
    disablesThinking: Bool
  ) throws -> (history: [Chat.Message], current: Chat.Message) {
    guard let current = request.messages.last, current.role == .user || current.role == .tool, !current.content.isEmpty else {
      throw ModelGenerationFailure(.invalidRequest, "MLX generation requires a final user or tool message.")
    }
    var history = try request.messages.dropLast().map(Self.message)
    if case .jsonObject(let schema) = request.outputFormat {
      let encoded = try MLXGrammarSchema.encode(schema)
      let instruction = "Return only a JSON object conforming to this schema. Include every required field. No markdown or explanation. Schema: " + encoded
      if history.first?.role == .system {
        history[0].content += "\n\n" + instruction
      } else {
        history.insert(.system(instruction), at: 0)
      }
    }
    var mapped = try message(current)
    if disablesThinking && current.role == .user { mapped.content += "\n/no_think" }
    return (history, mapped)
  }

  static func tool(_ tool: ModelTool) -> ToolSpec {
    ["type": "function", "function": [
      "name": tool.name, "description": tool.description,
      "parameters": sendable(tool.inputSchema),
    ] as [String: any Sendable]]
  }

  private static func sendable(_ value: LanguageModelCore.JSONValue) -> any Sendable {
    switch value {
    case .null: NSNull()
    case .bool(let value): value
    case .integer(let value): value
    case .number(let value): value
    case .string(let value): value
    case .array(let value): value.map(sendable)
    case .object(let value): value.mapValues(sendable)
    }
  }

  private static func message(_ message: AgentMessage) throws -> Chat.Message {
    switch message.role {
    case .system:
      .system(message.content)
    case .user:
      .user(message.content)
    case .assistant:
      .assistant(message.content, toolCalls: try message.toolCalls.map { call in
        let arguments = try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self,
          from: JSONEncoder().encode(call.arguments))
        return MLXLMCommon.ToolCall(function: .init(name: call.name, arguments: arguments), id: call.id)
      })
    case .tool:
      .tool(message.content, id: message.toolCallID)
    }
  }
}
