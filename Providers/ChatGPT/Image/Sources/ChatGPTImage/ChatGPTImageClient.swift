import Foundation
@_spi(Service) import ChatGPTAccount
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// ChatGPT-subscription image endpoint client.
///
/// The subscription route follows the pinned Codex image contract: one canonical
/// `gpt-image-2` model, `background=auto` on the wire, and semantic background intent preserved
/// in the prompt. The host verifies returned PNG pixels before declaring the requested background
/// constraint complete.
public struct ChatGPTImageClient: Sendable {
  public static let model = ChatGPTImageLimits.model
  public static let maximumEditImages = ChatGPTImageLimits.maximumEditImages
  public static let maximumInputImageBytes = ChatGPTImageLimits.maximumInputImageBytes
  public static let maximumImageBytes = ChatGPTImageLimits.maximumImageBytes
  public static let maximumPromptUTF8Bytes = ChatGPTImageLimits.maximumPromptUTF8Bytes
  public static let maximumPNGPixelCount = ChatGPTImageLimits.maximumPNGPixelCount
  public static let maximumPNGDecodedBytes = ChatGPTImageLimits.maximumPNGDecodedBytes
  public static let defaultMaximumRequestBytes = ChatGPTImageLimits.defaultMaximumRequestBytes
  public static let maximumEditRequestBytes = ChatGPTImageLimits.maximumEditRequestBytes
  public static let minimumRequestOrResponseBytes = ChatGPTImageLimits.minimumRequestOrResponseBytes
  public static let defaultMaximumResponseBytes = ChatGPTImageLimits.defaultMaximumResponseBytes

  // Struct copies share quarantine for operations dispatched by this client.
  private let operationGate = ChatGPTImageOperationGate()
  private let account: ChatGPTAccountSession
  private let transport: any ChatGPTTransport
  private let maxRequestBytes: Int
  private let maxResponseBytes: Int

  public init(
    account: ChatGPTAccountSession,
    transport: any ChatGPTTransport = URLSessionChatGPTTransport(),
    maxResponseBytes: Int = Self.defaultMaximumResponseBytes,
    maxRequestBytes: Int = Self.defaultMaximumRequestBytes
  ) throws {
    guard (Self.minimumRequestOrResponseBytes...Self.defaultMaximumResponseBytes).contains(maxResponseBytes),
      (Self.minimumRequestOrResponseBytes...Self.maximumEditRequestBytes).contains(maxRequestBytes)
    else {
      throw ChatGPTImageFailure(.invalidRequest)
    }
    self.account = account
    self.transport = transport
    self.maxRequestBytes = maxRequestBytes
    self.maxResponseBytes = maxResponseBytes
  }

  public func generate(_ request: ChatGPTImageGenerationRequest) async throws -> ChatGPTImageResult {
    do {
      try ChatGPTImageWireCodec.validatePrompt(request.prompt)
      let prompt = Self.promptPreservingBackgroundIntent(
        request.prompt,
        background: request.background
      )
      let body = try ChatGPTImageWireCodec.encodeGenerationRequest(
        prompt: prompt,
        background: .auto,
        quality: request.quality,
        size: request.size,
        model: Self.model,
        maximumRequestBytes: maxRequestBytes
      )
      let profile = await account.protocolProfile()
      return try await perform(
        endpoint: profile.imageGenerationsEndpoint,
        body: body,
        turnID: request.turnID
      )
    } catch let error as ChatGPTTransportDrainFailure {
      operationGate.quarantine(error)
      throw ChatGPTImageOperationGate.failure
    } catch {
      throw Self.failure(error)
    }
  }

  public func edit(_ request: ChatGPTImageEditRequest) async throws -> ChatGPTImageResult {
    do {
      try ChatGPTImageWireCodec.validatePrompt(request.prompt)
      let prompt = Self.promptPreservingBackgroundIntent(
        request.prompt,
        background: request.background
      )
      let body = try ChatGPTImageWireCodec.encodeEditRequest(
        images: request.images,
        prompt: prompt,
        background: .auto,
        quality: request.quality,
        size: request.size,
        model: Self.model,
        maximumEditImages: Self.maximumEditImages,
        maximumInputImageBytes: Self.maximumInputImageBytes,
        maximumRequestBytes: maxRequestBytes,
        maximumPNGPixelCount: Self.maximumPNGPixelCount,
        maximumPNGDecodedBytes: Self.maximumPNGDecodedBytes
      )
      let profile = await account.protocolProfile()
      return try await perform(
        endpoint: profile.imageEditsEndpoint,
        body: body,
        turnID: request.turnID
      )
    } catch let error as ChatGPTTransportDrainFailure {
      operationGate.quarantine(error)
      throw ChatGPTImageOperationGate.failure
    } catch {
      throw Self.failure(error)
    }
  }

  static func promptPreservingBackgroundIntent(
    _ prompt: String,
    background: ChatGPTImageBackground
  ) -> String {
    let requirement: String?
    switch background {
    case .transparent:
      requirement =
        "Output a PNG with a genuinely transparent background using true alpha transparency. " +
        "Do not paint a checkerboard, white backdrop, solid backdrop, or faux transparency."
    case .opaque:
      requirement =
        "Output a fully opaque PNG background with no transparent pixels."
    case .auto:
      requirement = nil
    }
    return [prompt, requirement]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  private func perform(endpoint: URL, body: Data, turnID: UUID) async throws -> ChatGPTImageResult {
    try Task.checkCancellation()
    try operationGate.checkAdmission()
    var authorization = try await account.requestAuthorization()
    let initialAuthorization = authorization
    let profile = await account.protocolProfile()
    for attempt in 0..<ChatGPTSubscriptionRetryPolicy.authenticationAttemptCount {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      try Task.checkCancellation()
      try await account.validateAuthorization(initialAuthorization)
      try authorization.apply(to: &request)
      request.setValue(profile.clientVersion, forHTTPHeaderField: "Version")
      request.setValue(profile.originator, forHTTPHeaderField: "Originator")
      request.setValue(turnID.uuidString.lowercased(), forHTTPHeaderField: "x-codex-image-turn-id")
      request.setValue(chatGPTUserAgent(profile: profile), forHTTPHeaderField: "User-Agent")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.httpBody = body

      try operationGate.checkAdmission()
      let response = try await ChatGPTImageWireCodec.response(
        transport: transport,
        request: request,
        maximumBytes: maxResponseBytes
      )
      if response.status == 401,
        ChatGPTSubscriptionRetryPolicy.permitsAuthenticationRefresh(after: attempt)
      {
        try await account.validateAuthorization(initialAuthorization)
        authorization = try await account.requestAuthorization(forceRefresh: true)
        try await account.validateAuthorization(initialAuthorization)
        continue
      }
      guard (200...299).contains(response.status) else {
        throw ChatGPTImageWireCodec.rejection(
          status: response.status,
          headers: response.headers,
          body: response.body)
      }

      let decoded = try ChatGPTImageWireCodec.decodeResponse(
        response.body,
        maximumImageBytes: Self.maximumImageBytes,
        maximumPNGPixelCount: Self.maximumPNGPixelCount,
        maximumPNGDecodedBytes: Self.maximumPNGDecodedBytes
      )
      try Task.checkCancellation()
      return decoded.withImageGenerationRequestID(
        ChatGPTImageWireCodec.requestID(response.headers)
      )
    }
    throw ChatGPTImageFailure(.authenticationRequired)
  }

  private static func failure(_ error: any Error) -> ChatGPTImageFailure {
    if let failure = error as? ChatGPTImageFailure { return failure }
    if error is CancellationError || Task.isCancelled { return ChatGPTImageFailure(.cancelled) }
    if let failure = error as? ChatGPTFailure {
      switch failure.code {
      case .signInRequired, .authorizationExpired, .tokenRefreshFailed:
        return ChatGPTImageFailure(.authenticationRequired)
      case .rateLimited: return ChatGPTImageFailure(.rateLimited)
      case .invalidConfiguration, .modelUnavailable: return ChatGPTImageFailure(.invalidRequest)
      case .signInCancelled: return ChatGPTImageFailure(.cancelled)
      case .malformedResponse: return ChatGPTImageFailure(.malformedResponse)
      case .serviceRejected: return ChatGPTImageFailure(.serviceRejected)
      case .authorizationFailed, .credentialStorageFailed, .tokenRefreshUnavailable,
        .transportFailure:
        return ChatGPTImageFailure(.transportFailure)
      }
    }
    if let wire = error as? ChatGPTTransportError {
      switch wire {
      case .limitExceeded, .responseTooLarge:
        return ChatGPTImageFailure(.limitExceeded)
      default: return ChatGPTImageFailure(.transportFailure)
      }
    }
    return ChatGPTImageFailure(.transportFailure)
  }
}

private extension ChatGPTImageResult {
  func withImageGenerationRequestID(_ requestID: String?) -> ChatGPTImageResult {
    ChatGPTImageResult(
      image: image,
      createdAt: createdAt,
      background: background,
      quality: quality,
      size: size,
      imageGenerationRequestID: requestID.flatMap { $0.isEmpty ? nil : $0 }
    )
  }
}

/// Per-client local resource safety, not account credentials or image history.
/// No lock is held across I/O; already-admitted concurrent calls retain their own
/// producer. Every failed receipt stays retained until the client is released.
private final class ChatGPTImageOperationGate: @unchecked Sendable {
  private enum State {
    case open
    case quarantined([ChatGPTTransportDrainFailure])
  }
  static let failure = ChatGPTImageFailure(
    .transportFailure, responseCode: "local_completion_unproved")
  private let lock = NSLock()
  private var state: State = .open

  func checkAdmission() throws {
    try lock.withLock {
      if case .quarantined = state { throw Self.failure }
    }
  }

  func quarantine(_ failure: ChatGPTTransportDrainFailure) {
    lock.withLock {
      switch state {
      case .open: state = .quarantined([failure])
      case .quarantined(var failures):
        failures.append(failure)
        state = .quarantined(failures)
      }
    }
  }
}
