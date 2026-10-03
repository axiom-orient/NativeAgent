import Foundation
import NativeAgentDomain

/// Request-only instructions. Durable system messages are the immutable baseline, so language
/// policies from previous turns never accumulate. The exact result is budgeted and fingerprinted
/// by the normal request/ledger path before any provider invocation.
struct TurnPromptProjection {
  let message: AgentMessage
  let userMessage: AgentMessage?
  let additionalTokens: Int
  let minimumRetainedMessageIndex: Int

  static func make(
    snapshot: SessionSnapshot,
    tools: [ToolDefinition],
    augmentor: (any PromptAugmentor)?
  ) async throws -> Self? {
    guard let augmentor else { return nil }
    let users = snapshot.messages.filter {
      $0.role == .user && $0.metadata[ResponseContinuationMetadata.syntheticRequestKey] != .bool(true)
    }
    guard let user = users.last else { return nil }
    let prefix = Array(snapshot.messages.prefix(while: { $0.role == .system }))
    // Session-start facade metadata supplies the first turn. Subsequent turns use only their
    // own options; otherwise an initial polish/language selection would silently become sticky.
    var metadata = users.count == 1 ? snapshot.metadata : [:]
    metadata.merge(user.metadata) { _, new in new }
    let request = PromptAugmentationRequest(
      sessionID: snapshot.sessionID,
      basePrompt: prefix.map(\.content).joined(separator: "\n\n"),
      userPrompt: user.content,
      title: snapshot.title,
      modelID: snapshot.modelID,
      metadata: metadata,
      availableTools: tools
    )
    let prompt = try await augmentor.augmentSystemPrompt(request)
    let projectedInput = try await (augmentor as? any TurnInputProjector)?.projectUserPrompt(request)
    let projectedUser = projectedInput.map {
      AgentMessage(id: user.id, role: .user, content: $0, createdAt: user.createdAt, metadata: user.metadata)
    }
    // A turn augmentor must not silently erase the enduring instruction layer.
    guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentError.invalidConfiguration("Turn prompt augmentation returned empty instructions.")
    }
    let message = AgentMessage(
      id: prefix.first?.id ?? "\(user.id).turn-instructions",
      role: .system, content: prompt,
      createdAt: prefix.first?.createdAt ?? user.createdAt
    )
    let estimator = ApproximateTokenEstimator()
    let additionalTokens = max(0,
      try estimator.estimate(messages: [message], tools: [])
        - estimator.estimate(messages: prefix, tools: []))
    guard let index = snapshot.messages.lastIndex(where: { $0.id == user.id }) else {
      throw AgentError.invariantViolation("Active user turn is missing from the durable transcript.")
    }
    return Self(message: message, userMessage: projectedUser,
      additionalTokens: additionalTokens, minimumRetainedMessageIndex: index)
  }

  func reservingBudget(in policy: ContextBudgetPolicy?) -> ContextBudgetPolicy? {
    guard let policy else { return nil }
    // This is an approximate compaction reservation, not a claim about tokenizer accuracy.
    return ContextBudgetPolicy(
      windowTokens: policy.windowTokens,
      reservedOutputTokens: min(policy.windowTokens - 1, policy.reservedOutputTokens + additionalTokens),
      triggerRatio: policy.triggerRatio,
      targetRatio: policy.targetRatio,
      keepRecentMessages: policy.keepRecentMessages,
      maxSummaryCharacters: policy.maxSummaryCharacters,
      preserveSystemMessages: policy.preserveSystemMessages
    )
  }
}
