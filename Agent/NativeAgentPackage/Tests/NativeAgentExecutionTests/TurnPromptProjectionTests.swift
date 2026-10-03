import Foundation
import NativeAgentDomain
@testable import NativeAgentExecution
import Testing

struct TurnPromptProjectionTests {
  @Test
  func syntheticContinuationUsesActualSourceAndItsOptions() async throws {
    let snapshot = SessionSnapshot(sessionID: "turn", messages: [
      .init(id: "soul", role: .system, content: "Foundation"),
      .init(id: "first", role: .user, content: "old", metadata: ["operation": .string("old")]),
      .init(id: "second", role: .user, content: "current-source", metadata: ["operation": .string("current")]),
      .init(id: "auto", role: .user, content: "Continue", metadata: ["syntheticAutoContinuation": .bool(true)]),
    ])
    let projection = try #require(try await TurnPromptProjection.make(
      snapshot: snapshot, tools: [], augmentor: EchoTurnAugmentor()))
    #expect(projection.message.content == "Foundation\ncurrent-source\ncurrent")
    #expect(projection.minimumRetainedMessageIndex == 2)
    let repeated = try await TurnPromptProjection.make(snapshot: snapshot, tools: [], augmentor: EchoTurnAugmentor())
    #expect(repeated?.message == projection.message)
    #expect(snapshot.messages[0].content == "Foundation")
  }

  @Test
  func activeSourceAndFollowingToolMessagesCannotBeSummarized() throws {
    let source = String(repeating: "current original paragraph. ", count: 150)
    let snapshot = SessionSnapshot(sessionID: "source", messages: [
      .init(id: "soul", role: .system, content: "Stable soul"),
      .init(id: "old-user", role: .user, content: String(repeating: "past context ", count: 250)),
      .init(id: "old-answer", role: .assistant, content: String(repeating: "past answer ", count: 250)),
      .init(id: "source", role: .user, content: source),
      .init(id: "continue", role: .user, content: "Continue", metadata: ["syntheticAutoContinuation": .bool(true)]),
    ])
    let compaction = try #require(try ContextWindowCompactor().compactIfNeeded(
      snapshot: snapshot, tools: [],
      policy: .init(windowTokens: 1_000, reservedOutputTokens: 100, keepRecentMessages: 0, maxSummaryCharacters: 200),
      minimumRetainedMessageIndex: 3))
    #expect(compaction.checkpoint?.coveredMessageCount == 3)
    #expect(compaction.messages.contains { $0.id == "source" && $0.content == source })
    #expect(compaction.messages.last?.id == "continue")
  }

  @Test
  func dynamicInstructionsParticipateInExactRequestLimits() throws {
    let snapshot = SessionSnapshot(sessionID: "limit", messages: [
      .init(id: "soul", role: .system, content: "Soul"),
      .init(id: "user", role: .user, content: "Hello"),
    ])
    _ = try AgentLoopRequestBuilder().makeProjection(snapshot: snapshot, messages: snapshot.messages, tools: [], checkpointApplied: false)
    let oversized = AgentMessage(id: "soul", role: .system, content: String(repeating: "x", count: 2 * 1_024 * 1_024))
    let builder = AgentLoopRequestBuilder(systemPromptOverride: oversized)
    #expect(throws: ModelGenerationFailure.self) {
      try builder.makeProjection(snapshot: snapshot, messages: snapshot.messages, tools: [], checkpointApplied: false)
    }
    // Removing history cannot hide an oversized dynamic prompt, so no lossy checkpoint is licensed.
    #expect(throws: ModelGenerationFailure.self) {
      try builder.requiresHardCompaction(snapshot: snapshot, messages: snapshot.messages, tools: [])
    }
  }

  @Test
  func augmentationReservesCompactionSpaceAndKeepsNoHookBehavior() async throws {
    let snapshot = SessionSnapshot(sessionID: "reserve", messages: [
      .init(id: "user", role: .user, content: String(repeating: "source ", count: 100)),
    ])
    #expect(try await TurnPromptProjection.make(snapshot: snapshot, tools: [], augmentor: nil) == nil)
    let projected = try #require(try await TurnPromptProjection.make(snapshot: snapshot, tools: [], augmentor: EchoTurnAugmentor()))
    let policy = ContextBudgetPolicy(windowTokens: 4_096, reservedOutputTokens: 512)
    let reserved = try #require(projected.reservingBudget(in: policy))
    #expect(projected.additionalTokens > 0)
    #expect(reserved.reservedOutputTokens > policy.reservedOutputTokens)
    #expect(reserved.targetTokens < policy.targetTokens)
  }

  @Test
  func twoInputProjectorsCannotSilentlyCompeteForTheSameSource() async throws {
    let chain = PromptAugmentorChain([ProjectingTurnAugmentor(), ProjectingTurnAugmentor()])
    await #expect(throws: AgentError.self) {
      try await chain.projectUserPrompt(.init(sessionID: "conflict", userPrompt: "original"))
    }
  }
}

private struct ProjectingTurnAugmentor: PromptAugmentor, TurnInputProjector {
  func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String? { request.basePrompt }
  func projectUserPrompt(_ request: PromptAugmentationRequest) async throws -> String? { "projected" }
}

private struct EchoTurnAugmentor: PromptAugmentor {
  func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
    request.normalizedBasePrompt + "\n" + request.userPrompt + "\n" + (request.metadata["operation"]?.stringValue ?? "")
  }
}
