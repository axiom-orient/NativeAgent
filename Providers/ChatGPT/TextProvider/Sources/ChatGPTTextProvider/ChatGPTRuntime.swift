import ChatGPTAccount
import ChatGPTText
import LanguageModelCore
import LanguageModelRuntime

/// Creates the canonical runtime for a signed-in ChatGPT subscription account.
///
/// `ChatGPTAccount` owns credentials/refresh; `ChatGPTText` owns model
/// discovery and Responses transport. This provider only admits that signed-in
/// capability into the canonical `ModelRuntime`, which remains the sole model
/// lifecycle authority exposed to the Agent layer.
public enum ChatGPTRuntime {
  public static let providerID = "chatgpt.subscription"
  public static let capabilities: ModelCapabilities = [
    .textInput, .textOutput, .streaming, .structuredOutput, .toolCalls,
  ]

  public static func makeRuntime(
    account: ChatGPTAccountSession,
    model selection: ChatGPTModelSelection = .recommended,
    runtimeID: ModelRuntimeID? = nil,
    policy: ModelRuntimePolicy = .default
  ) async throws -> ModelRuntime {
    try await makeRuntime(
      text: ChatGPTTextSession(account: account), model: selection,
      runtimeID: runtimeID, policy: policy)
  }

  public static func makeRuntime(
    text: ChatGPTTextSession,
    model selection: ChatGPTModelSelection = .recommended,
    runtimeID: ModelRuntimeID? = nil,
    policy: ModelRuntimePolicy = .default
  ) async throws -> ModelRuntime {
    let account = text.account
    try admitRuntimeCreation(for: try await account.status())

    // `models()` owns credential refresh and the one unauthorized catalog retry.
    let resolved = try await resolveModel(text: text, selection: selection)
    let descriptor = try descriptor(for: resolved)

    let client = try ChatGPTModelClient(
      text: text,
      model: .exact(resolved.slug),
      providerID: providerID,
      modelDescriptor: descriptor
    )

    return try ModelRuntime(
      id: runtimeID ?? ModelRuntimeID(rawValue: "chatgpt.subscription.\(resolved.slug)"),
      model: try ClientLanguageModel(client: client, descriptor: descriptor),
      policy: policy
    )
  }

  static func descriptor(for model: ChatGPTModelInfo) throws -> ModelDescriptor {
    let descriptor = ModelDescriptor(
      id: model.slug,
      providerID: providerID,
      displayName: model.displayName ?? model.slug,
      capabilities: capabilities,
      contextWindowTokens: model.contextWindow.flatMap(Int.init(exactly:))
    )
    try descriptor.validateGenerationContract()
    return descriptor
  }

  /// Pure account admission shared by runtime creation and optional host composition.
  public static func admitRuntimeCreation(for status: ChatGPTSubscriptionStatus) throws {
    switch status {
    case .ready, .expired:
      return
    case .signedOut, .authorizing:
      throw ModelGenerationFailure(
        .authenticationRequired,
        "ChatGPT subscription sign-in is required before creating a model runtime."
      )
    }
  }

  private static func resolveModel(
    text: ChatGPTTextSession,
    selection: ChatGPTModelSelection
  ) async throws -> ChatGPTModelInfo {
    do {
      return try await text.resolvedModel(for: selection)
    } catch let failure as ChatGPTFailure where failure.code == .modelUnavailable {
      switch selection {
      case .recommended:
        throw ModelGenerationFailure(
          .sourceUnavailable,
          "The ChatGPT subscription account has no selectable model."
        )
      case .exact:
        throw ModelGenerationFailure(
          .invalidRequest,
          "The requested ChatGPT subscription model is not available to this account."
        )
      }
    }
  }
}
