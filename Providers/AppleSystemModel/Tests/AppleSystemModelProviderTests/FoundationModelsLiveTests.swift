#if canImport(FoundationModels)
  import Foundation
  import Testing
  import LanguageModelCore
  import LanguageModelRuntime
  import AppleSystemModelProvider

  @Test(.enabled(if: ProcessInfo.processInfo.environment["NATIVEAGENT_LIVE_FOUNDATION"] == "1"))
  @available(macOS 26.0, iOS 26.0, *)
  func foundationModelsRealGeneration() async throws {
    let runtime = try AppleSystemModelProvider.makeRuntime()
    do {
      let turn = try await runtime.generate(
        ModelRequest(
          sessionID: "foundation-live",
          messages: [.init(role: .user, content: "What is two plus two? Answer briefly.")],
          tools: []))
      #expect(!turn.content.isEmpty)
      print("LIVE FoundationModels: nonempty system-model generation observed")
      try await runtime.shutdown()
    } catch {
      try await runtime.shutdown()
      throw error
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["NATIVEAGENT_LIVE_FOUNDATION"] == "1"))
  @available(macOS 26.0, iOS 26.0, *)
  func foundationModelsRealCancellationAndReuse() async throws {
    let runtime = try AppleSystemModelProvider.makeRuntime()
    do {
      let run = try await runtime.start(
        ModelRequest(
          sessionID: "foundation-cancel",
          messages: [
            .init(
              role: .user,
              content: "List 100 different animals, each with a sentence describing its habitat.")
          ], tools: []))
      var observedDelta = false
      var observedCancellation = false
      do {
        for try await event in run.events {
          if case .textDelta = event, !observedDelta {
            observedDelta = true
            await run.cancel()
          }
        }
      } catch let failure as ModelGenerationFailure {
        observedCancellation = failure.code == .cancelled
      } catch is CancellationError { observedCancellation = true }
      try #require(observedDelta && observedCancellation)
      let next = try await runtime.generate(
        ModelRequest(
          sessionID: "foundation-reuse",
          messages: [
            .init(
              role: .user,
              content: "What is two plus two? Answer briefly.")
          ], tools: []))
      try #require(!next.content.isEmpty)
      try await runtime.shutdown()
      print("LIVE FoundationModels: cancellation after delta, drain, reuse and shutdown observed")
    } catch {
      try await runtime.shutdown()
      throw error
    }
  }

#endif
