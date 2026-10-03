import Foundation

@_spi(Service) public enum ChatGPTSubscriptionRetryPolicy {
  public static let authenticationAttemptCount = 2

  public static func permitsAuthenticationRefresh(after attempt: Int) -> Bool {
    attempt >= 0 && attempt < authenticationAttemptCount - 1
  }
}

/// Immutable wire profile for the ChatGPT-managed Codex service.
///
/// These values are protocol identity, not secrets. Keeping them in one validated value avoids
/// scattering endpoint, client, and fingerprint literals through the package or host app.
public struct ChatGPTProtocolProfile: Hashable, Sendable {
  public static let defaultCallbackPort: UInt16 = 1_455
  public static let fallbackCallbackPort: UInt16 = 1_457
  public static let registeredCallbackPorts: [UInt16] = [defaultCallbackPort, fallbackCallbackPort]
  public static let maximumProtocolIdentityUTF8Bytes = 256

  public let issuer: URL
  public let responsesEndpoint: URL
  public let imageGenerationsEndpoint: URL
  public let imageEditsEndpoint: URL
  public let modelsEndpoint: URL
  public let usageEndpoint: URL
  public let redirectURI: URL
  public let clientID: String
  public let originator: String
  public let clientVersion: String
  public let sourceRevision: String

  private init(
    issuer: URL,
    responsesEndpoint: URL,
    imageGenerationsEndpoint: URL,
    imageEditsEndpoint: URL,
    modelsEndpoint: URL,
    usageEndpoint: URL,
    redirectURI: URL,
    clientID: String,
    originator: String,
    clientVersion: String,
    sourceRevision: String
  ) throws {
    for url in [
      issuer, responsesEndpoint, imageGenerationsEndpoint, imageEditsEndpoint, modelsEndpoint,
      usageEndpoint,
    ] {
      guard url.scheme == "https", url.user == nil, url.password == nil,
        url.query == nil, url.fragment == nil, url.host?.isEmpty == false
      else { throw ChatGPTFailure(.invalidConfiguration) }
    }
    try Self.validateCallbackRedirectURI(redirectURI)
    for value in [clientID, originator, clientVersion, sourceRevision] {
      guard !value.isEmpty, value.utf8.count <= Self.maximumProtocolIdentityUTF8Bytes,
        value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7F })
      else { throw ChatGPTFailure(.invalidConfiguration) }
    }
    self.issuer = issuer
    self.responsesEndpoint = responsesEndpoint
    self.imageGenerationsEndpoint = imageGenerationsEndpoint
    self.imageEditsEndpoint = imageEditsEndpoint
    self.modelsEndpoint = modelsEndpoint
    self.usageEndpoint = usageEndpoint
    self.redirectURI = redirectURI
    self.clientID = clientID
    self.originator = originator
    self.clientVersion = clientVersion
    self.sourceRevision = sourceRevision
  }

  /// Pinned service profile derived from the referenced OpenAI Codex client revision.
  /// Runtime proof is tracked separately from this pin.
  public static let codexSubscription = try! Self(
    issuer: URL(string: "https://auth.openai.com")!,
    responsesEndpoint: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
    imageGenerationsEndpoint: URL(
      string: "https://chatgpt.com/backend-api/codex/images/generations")!,
    imageEditsEndpoint: URL(string: "https://chatgpt.com/backend-api/codex/images/edits")!,
    modelsEndpoint: URL(string: "https://chatgpt.com/backend-api/codex/models")!,
    usageEndpoint: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
    redirectURI: try! Self.callbackRedirectURI(port: Self.defaultCallbackPort),
    clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
    originator: "codex_cli_rs",
    clientVersion: "0.153.4",
    sourceRevision: "openai/codex:rust-v0.153.4@3d2ee51ca2d5db578f328aa75e20aa22c0197c9a"
  )

  /// Bearer-bearing service calls must stay on the pinned service origin.
  @_spi(Service) public func validateServiceEndpoint(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https",
      url.host?.lowercased() == responsesEndpoint.host?.lowercased(),
      (url.port ?? 443) == (responsesEndpoint.port ?? 443),
      url.user == nil, url.password == nil, url.fragment == nil
    else { throw ChatGPTFailure(.invalidConfiguration) }
  }

  public static func callbackRedirectURI(port: UInt16) throws -> URL {
    guard registeredCallbackPorts.contains(port),
      let redirectURI = URL(string: "http://localhost:\(port)/auth/callback")
    else { throw ChatGPTFailure(.invalidConfiguration) }
    return redirectURI
  }

  public static func validateCallbackRedirectURI(_ redirectURI: URL) throws {
    guard redirectURI.scheme == "http",
      ["localhost", "127.0.0.1"].contains(redirectURI.host?.lowercased() ?? ""),
      redirectURI.port.flatMap(UInt16.init(exactly:)).map(registeredCallbackPorts.contains) == true,
      redirectURI.path == "/auth/callback",
      redirectURI.user == nil, redirectURI.password == nil,
      redirectURI.query == nil, redirectURI.fragment == nil
    else { throw ChatGPTFailure(.invalidConfiguration) }
  }
}

public enum ChatGPTErrorCode: String, Codable, Hashable, Sendable {
  case invalidConfiguration
  case signInRequired
  case signInCancelled
  case authorizationExpired
  case authorizationFailed
  case credentialStorageFailed
  case tokenRefreshFailed
  case tokenRefreshUnavailable
  case modelUnavailable
  case transportFailure
  case malformedResponse
  case serviceRejected
  case rateLimited
}

public struct ChatGPTFailure: Error, Codable, Hashable, Sendable, LocalizedError {
  public let code: ChatGPTErrorCode
  public let message: String

  public init(_ code: ChatGPTErrorCode) {
    self.code = code
    self.message = Self.message(for: code)
  }

  public var errorDescription: String? { "\(code.rawValue): \(message)" }

  private static func message(for code: ChatGPTErrorCode) -> String {
    switch code {
    case .invalidConfiguration: "ChatGPT subscription configuration is invalid."
    case .signInRequired: "Sign in with ChatGPT is required."
    case .signInCancelled: "ChatGPT sign-in was cancelled."
    case .authorizationExpired: "The ChatGPT authorization code expired."
    case .authorizationFailed: "ChatGPT authorization failed."
    case .credentialStorageFailed: "ChatGPT credentials could not be stored securely."
    case .tokenRefreshFailed: "The ChatGPT session could not be refreshed. Sign in again."
    case .tokenRefreshUnavailable: "The ChatGPT session refresh service is temporarily unavailable."
    case .modelUnavailable: "No compatible ChatGPT subscription model is available."
    case .transportFailure: "The ChatGPT service could not be reached."
    case .malformedResponse: "The ChatGPT service returned an invalid response."
    case .serviceRejected: "The ChatGPT service rejected the request."
    case .rateLimited: "The ChatGPT subscription usage limit was reached."
    }
  }
}

public struct ChatGPTWebAuthorization: Hashable, Sendable {
  public let authorizationURL: URL
  public let expiresAt: Date
  let redirectURI: URL
  let state: String
  let verifier: String
}

public struct ChatGPTAccount: Codable, Hashable, Sendable {
  public let accountID: String
  public let plan: String?
  public let email: String?
}

public enum ChatGPTSubscriptionStatus: Hashable, Sendable {
  case signedOut
  case authorizing(ChatGPTWebAuthorization)
  case ready(ChatGPTAccount)
  case expired
}

