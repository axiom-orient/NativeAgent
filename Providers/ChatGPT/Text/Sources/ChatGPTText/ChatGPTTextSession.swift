import Foundation
@_spi(Service) import ChatGPTAccount

/// Text-service metadata for one account. No credential storage or image state is owned here.
public actor ChatGPTTextSession {
  public nonisolated let account: ChatGPTAccountSession

  private struct Catalog {
    let generation: UInt64
    let models: [ChatGPTModelInfo]
    let authorization: ChatGPTRequestAuthorization
  }
  private var catalog: Catalog?
  private var catalogGeneration: UInt64 = 0

  public init(account: ChatGPTAccountSession) { self.account = account }

  public func resolvedModel(for selection: ChatGPTModelSelection) async throws -> ChatGPTModelInfo {
    let models = try await models()
    switch selection {
    case .recommended:
      return try ChatGPTTextPayload.selectRecommendedModel(from: models)
    case .exact(let identifier):
      try chatGPTValidateModel(identifier)
      guard let model = models.first(where: { $0.slug == identifier }) else {
        throw ChatGPTFailure(.modelUnavailable)
      }
      return model
    }
  }

  func modelID(for selection: ChatGPTModelSelection) async throws -> String {
    try await resolvedModel(for: selection).slug
  }

  public func models(forceRefresh: Bool = false) async throws -> [ChatGPTModelInfo] {
    try Task.checkCancellation()
    if !forceRefresh, let catalog {
      do {
        try await account.validateAuthorization(catalog.authorization)
        try Task.checkCancellation()
        return catalog.models
      } catch let failure as ChatGPTFailure where failure.code == .signInRequired {
        // Invalidate only the observed snapshot. A reauthenticated account gets a new request;
        // a signed-out account still fails at authenticatedGET without any service dispatch.
        if self.catalog?.generation == catalog.generation { self.catalog = nil }
      }
    }
    catalogGeneration &+= 1
    let generation = catalogGeneration
    let profile = await account.protocolProfile()
    let url = profile.modelsEndpoint.appending(
      queryItems: [URLQueryItem(name: "client_version", value: profile.clientVersion)])
    let response = try await account.authenticatedGET(to: url)
    guard response.statusCode == 200 else { throw Self.failure(response.statusCode) }
    let object = try ChatGPTTextPayload.object(response.body)
    guard let rawModels = object["models"] as? [[String: Any]] else {
      throw ChatGPTFailure(.malformedResponse)
    }
    let models = rawModels.compactMap(ChatGPTModelInfo.init)
    try await account.validateAuthorization(response.authorization)
    try Task.checkCancellation()
    if generation == catalogGeneration {
      catalog = Catalog(generation: generation, models: models, authorization: response.authorization)
    }
    return models
  }

  public func rateLimits() async throws -> ChatGPTRateLimitSnapshot {
    let profile = await account.protocolProfile()
    let response = try await account.authenticatedGET(to: profile.usageEndpoint)
    guard response.statusCode == 200 else { throw Self.failure(response.statusCode) }
    try Task.checkCancellation()
    return try ChatGPTTextPayload.parseRateLimits(response.body)
  }

  private static func failure(_ status: Int) -> ChatGPTFailure {
    if status == 429 { return ChatGPTFailure(.rateLimited) }
    if status == 401 || status == 403 { return ChatGPTFailure(.signInRequired) }
    if (400...599).contains(status) { return ChatGPTFailure(.serviceRejected) }
    return ChatGPTFailure(.malformedResponse)
  }
}
