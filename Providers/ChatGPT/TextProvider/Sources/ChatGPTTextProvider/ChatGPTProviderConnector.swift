import ChatGPTAccount
import ChatGPTText
import LanguageModelCore
import LanguageModelRuntime

/// Provider-registry adapter for one host-owned ChatGPT account session.
/// Authentication presentation remains a host responsibility.
public struct ChatGPTProviderConnector: ModelProviderConnector {
  public let descriptor: ModelProviderDescriptor
  private let text: ChatGPTTextSession
  private var account: ChatGPTAccountSession { text.account }
  private let policy: ModelRuntimePolicy

  public init(
    account: ChatGPTAccountSession,
    policy: ModelRuntimePolicy = .default
  ) throws {
    self.text = ChatGPTTextSession(account: account)
    self.policy = policy
    self.descriptor = try ModelProviderDescriptor(
      id: ChatGPTRuntime.providerID,
      displayName: "ChatGPT",
      kind: .remote
    )
  }

  public func availability() async throws -> ModelProviderAvailability {
    switch try await account.status() {
    case .ready, .expired:
      return .available
    case .signedOut, .authorizing:
      return .authenticationRequired
    }
  }

  public func models() async throws -> [ModelDescriptor] {
    try await text.models().map(ChatGPTRuntime.descriptor(for:))
  }

  public func acquireRuntime(modelID: String?) async throws -> ModelRuntimeAccess {
    let selection: ChatGPTModelSelection = modelID.map(ChatGPTModelSelection.exact) ?? .recommended
    return .owned(try await ChatGPTRuntime.makeRuntime(
      text: text,
      model: selection,
      policy: policy
    ))
  }
}
