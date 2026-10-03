#if canImport(FoundationModels)
  import AppleLocalAI
  import Foundation
  import FoundationModels
  import LanguageModelCore
  import LanguageModelRuntime
  import Testing
  @testable import NativeAgentProviderAppleLocalAI

  /// Actual FoundationModels type/session tests. These are NOT executed by the
  /// Linux portable harness. The client is test-only, not native inference proof.
  @available(iOS 27.0, macOS 27.0, *)
  @Suite("FoundationModels borrowed runtime bridge")
  struct NativeRuntimeLanguageModelTests {
    @Test func textProjectionPreservesSegmentsWithoutInjectedWhitespace() throws {
      let runtime = try makeRuntime()
      let model = NativeAgentProviderAppleLocalAI.makeLanguageModel(
        runtime: runtime, sessionID: "apple")
      let executor = try NativeRuntimeExecutor(configuration: model.executorConfiguration)
      let request = try executor.project(
        generationRequest(segments: [
          .text(.init(id: "a", content: "  one")), .text(.init(id: "b", content: "two\n")),
        ]))
      #expect(request.messages.last?.content == "  onetwo\n")
      #expect(request.sessionID == "apple")
      #expect(request.modelID == runtime.modelDescriptor.id)
    }

    @Test func structuredHistoryRemainsJSONOnTheNextTurn() throws {
      let runtime = try makeRuntime()
      let model = NativeAgentProviderAppleLocalAI.makeLanguageModel(
        runtime: runtime, sessionID: "apple")
      let executor = try NativeRuntimeExecutor(configuration: model.executorConfiguration)
      let value = try GeneratedContent(json: "{\"answer\":42}")
      let history: [Transcript.Entry] = [
        .response(
          .init(
            id: "previous", assetIDs: [],
            segments: [
              .structure(.init(id: "json", schemaName: "Answer", content: value))
            ]))
      ]
      let projected = try executor.project(generationRequest(history: history))
      let restored = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(projected.messages[0].content.utf8))
      #expect(restored == .object(["answer": .integer(42)]))
    }

    @Test func unrepresentableOptionsAreRejectedBeforeIO() throws {
      let model = NativeAgentProviderAppleLocalAI.makeLanguageModel(
        runtime: try makeRuntime(), sessionID: "apple")
      let executor = try NativeRuntimeExecutor(configuration: model.executorConfiguration)
      #expect(throws: NativeRuntimeBridgeError.unsupportedGenerationOption(.temperature)) {
        _ = try executor.project(generationRequest(options: GenerationOptions(temperature: 0.5)))
      }
      #expect(throws: NativeRuntimeBridgeError.unsupportedGenerationOption(.maximumResponseTokens))
      {
        _ = try executor.project(
          generationRequest(options: GenerationOptions(maximumResponseTokens: 10)))
      }
      #expect(throws: NativeRuntimeBridgeError.unsupportedGenerationOption(.toolCallingMode)) {
        _ = try executor.project(
          generationRequest(options: GenerationOptions(toolCallingMode: .required)))
      }
      #expect(throws: NativeRuntimeBridgeError.metadataUnsupported) {
        _ = try executor.project(generationRequest(metadata: ["purpose": "fixture"]))
      }
    }

    @Test @MainActor func reverseBridgeRejectsRecursiveComposition() throws {
      let borrowed = NativeAgentProviderAppleLocalAI.makeLanguageModel(
        runtime: try makeRuntime(), sessionID: "apple")
      #expect(throws: NativeRuntimeBridgeError.recursiveComposition) {
        _ = try NativeAgentProviderAppleLocalAI.makeRuntime(
          model: borrowed,
          runtimeID: .init(rawValue: "recursive"), providerID: "test", modelID: "test", cleanup: {})
      }
    }

    @Test @MainActor func twoAppleSessionsBorrowOneBackendWithoutClosingIt() async throws {
      let backend = LocalBackend(load: { try makeRuntime() }, releaseResident: {})
      let native = try await backend.load()
      let first = AppleLocalAISession(
        profile: try AppleLocalAIProfile(
          model:
            NativeAgentProviderAppleLocalAI.makeLanguageModel(runtime: native, sessionID: "first")))
      let second = AppleLocalAISession(
        profile: try AppleLocalAIProfile(
          model:
            NativeAgentProviderAppleLocalAI.makeLanguageModel(runtime: native, sessionID: "second"))
      )
      let a = try await first.respond(AppleLocalAIRequest(prompt: Prompt("hello")))
      let b = try await second.respond(AppleLocalAIRequest(prompt: Prompt("again")))
      #expect(a.content == "test-only response")
      #expect(b.content == "test-only response")
      #expect(await native.status().phase == .idle)
      try await backend.shutdown()
      #expect(await native.status().phase == .closed)
    }
  }

  @available(iOS 27.0, macOS 27.0, *)
  private func generationRequest(
    history: [Transcript.Entry] = [],
    segments: [Transcript.Segment] = [.text(.init(id: "text", content: "hello"))],
    options: GenerationOptions = GenerationOptions(),
    metadata: [String: any ConvertibleToGeneratedContent] = [:]
  ) -> LanguageModelExecutorGenerationRequest {
    LanguageModelExecutorGenerationRequest(
      id: UUID(),
      transcript: Transcript(entries: history + [.prompt(.init(id: "prompt", segments: segments))]),
      enabledTools: [], generationOptions: options, contextOptions: ContextOptions(),
      metadata: metadata)
  }
  private struct FrameworkFixtureClient: ModelClient {
    let providerID = "test.framework"
    var modelDescriptor: ModelDescriptor? {
      .init(id: "fixture", providerID: providerID, capabilities: .textOnly)
    }
    func generate(request: ModelRequest) async throws -> ModelTurn {
      ModelTurn(content: "test-only response")
    }
  }
  private func makeRuntime() throws -> ModelRuntime {
    try ModelRuntime(id: .init(rawValue: "framework-fixture"), client: FrameworkFixtureClient())
  }
#endif
