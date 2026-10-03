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

  /// Drives LiteRT-LM generation through the Foundation Models executor contract.
  @available(iOS 27.0, macOS 27.0, *)
  public final class LiteRTLMExecutor: LanguageModelExecutor {
    public typealias Model = LiteRTLanguageModel

    /// The engine settings used to share one lazily loaded engine across sessions.
    public struct Configuration: Hashable, Sendable {
      public let engineConfig: EngineConfig

      public var modelPath: String { engineConfig.modelPath }

      public init(engineConfig: EngineConfig) {
        self.engineConfig = engineConfig
      }
    }

    private let engine: LazyEngine

    public init(configuration: Configuration) throws {
      self.engine = EngineCache.shared.engine(for: configuration)
    }

    public func prewarm(model: Model, transcript: Transcript) {
      Task {
        do {
          try await engine.prewarmed()
        } catch is CancellationError {
          return
        } catch {
          liteRTLogger.warning("LiteRT prewarm failed: \(String(describing: error))")
        }
      }
    }

    public func respond(
      to request: LanguageModelExecutorGenerationRequest,
      model: Model,
      streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
      try Task.checkCancellation()
      let maximumTokens = request.generationOptions.maximumResponseTokens
      if let maximumTokens, maximumTokens <= 0 || maximumTokens > Int(Int32.max) {
        throw LiteRTFMError.unsupported(
          "maximumResponseTokens is outside LiteRT's native Int32 range")
      }

      let sampler = try LiteRTSampler.make(request.generationOptions)
      let engine = try await engine.ready()
      let tools = request.enabledToolDefinitions
      let schemaJSON: String?
      if let schema = request.schema {
        let encoded = try LiteRTTranscriptPlanner.encodeSchema(schema)
        guard !encoded.isEmpty else {
          throw LiteRTFMError.unsupported("The requested schema encoded to an empty value")
        }
        schemaJSON = encoded
      } else {
        schemaJSON = nil
      }

      let plan = try LiteRTTranscriptPlanner.make(
        from: request.transcript,
        schemaJSON: schemaJSON,
        tools: tools)
      let responseFormat: ResponseFormat?
      if let schemaJSON {
        responseFormat = try ResponseFormat.json(schema: schemaJSON)
      } else {
        responseFormat = nil
      }

      let conversation = try await engine.createConversation(
        with: ConversationConfig(
          systemMessage: plan.systemMessage,
          initialMessages: plan.history,
          samplerConfig: sampler,
          enableResponseFormat: responseFormat != nil,
          visualTokenBudget: model.visualTokenBudget))

      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        if !tools.isEmpty || schemaJSON != nil {
          var full = ""
          for try await chunk in conversation.sendMessageStream(
            plan.prompt,
            maxOutputTokens: maximumTokens,
            responseFormat: tools.isEmpty ? responseFormat : nil)
          {
            try Task.checkCancellation()
            let delta = chunk.toString
            guard delta.utf8.count <= LiteRTDefaults.maximumBufferedResponseBytes - full.utf8.count
            else {
              throw LiteRTFMError.unsupported("Buffered LiteRT output exceeded its byte limit")
            }
            full += delta
          }
          try Task.checkCancellation()

          if !tools.isEmpty,
            let call = try LiteRTToolCallEnvelope.parse(full, allowedNames: Set(tools.map(\.name)))
          {
            await channel.send(
              .toolCalls(
                action: .toolCall(
                  id: UUID().uuidString,
                  name: call.name,
                  action: .appendArguments(call.arguments, tokenCount: call.arguments.count))))
          } else {
            if schemaJSON != nil {
              _ = try JSONSerialization.jsonObject(
                with: Data(full.utf8), options: [.fragmentsAllowed])
            }
            await channel.send(.response(action: .appendText(full, tokenCount: full.count)))
          }
        } else {
          for try await chunk in conversation.sendMessageStream(
            plan.prompt,
            maxOutputTokens: maximumTokens)
          {
            try Task.checkCancellation()
            let delta = chunk.toString
            if !delta.isEmpty {
              await channel.send(.response(action: .appendText(delta, tokenCount: 1)))
            }
          }
        }
        try Task.checkCancellation()
      } onCancel: {
        do { try conversation.cancel() } catch {
          liteRTLogger.error("LiteRT native cancellation failed: \(String(describing: error))")
        }
      }
    }

  }

#endif
