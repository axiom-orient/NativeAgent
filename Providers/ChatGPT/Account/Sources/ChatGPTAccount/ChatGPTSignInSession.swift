import Foundation

#if canImport(CryptoKit) && canImport(Network)
import CryptoKit
#endif

/// An owned authorization I/O boundary. Account owns its generation and commit;
/// the Apple implementation owns PKCE and the listener, never credentials.
struct ChatGPTSignInSession: Sendable {
  let authorization: ChatGPTWebAuthorization
  let waitForCallback: @Sendable (Date) async throws -> URL
  let cancel: @Sendable () async throws -> Void

  func stop() async throws {
    do { try await cancel() }
    catch { throw ChatGPTSignInDrainFailure(retaining: self) }
  }

  static func start(profile: ChatGPTProtocolProfile) async throws -> Self {
    #if canImport(CryptoKit) && canImport(Network)
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    do {
      try Task.checkCancellation()
      let authorization = try makeAuthorization(profile: profile, redirectURI: server.redirectURI)
      return Self(
        authorization: authorization,
        waitForCallback: { try await server.waitForCallback(until: $0) },
        cancel: { try await server.cancel() })
    } catch {
      // A listener acquired before cancellation remains owned until shutdown.
      do { try await server.cancel() }
      catch { throw ChatGPTSignInDrainFailure(cancel: { try await server.cancel() }) }
      throw error
    }
    #else
    // Explicitly unsupported. Never synthesize credentials, PKCE or a callback.
    throw ChatGPTFailure(.invalidConfiguration)
    #endif
  }

  #if canImport(CryptoKit) && canImport(Network)
  private enum Limits {
    static let authorizationLifetime: TimeInterval = 5 * 60
    static let pkceVerifierRandomBytes = 64
    static let authorizationStateRandomBytes = 32
  }

  private static func makeAuthorization(
    profile: ChatGPTProtocolProfile, redirectURI: URL
  ) throws -> ChatGPTWebAuthorization {
    try ChatGPTProtocolProfile.validateCallbackRedirectURI(redirectURI)
    let verifier = randomBase64URL(byteCount: Limits.pkceVerifierRandomBytes)
    let state = randomBase64URL(byteCount: Limits.authorizationStateRandomBytes)
    guard (43...128).contains(verifier.utf8.count),
      verifier.unicodeScalars.allSatisfy({ scalar in
        (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
          || (97...122).contains(scalar.value) || [45, 46, 95, 126].contains(scalar.value)
      })
    else { throw ChatGPTFailure(.invalidConfiguration) }
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    var components = URLComponents(
      url: try profile.issuer.appendingValidated(path: "oauth/authorize"),
      resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: profile.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "id_token_add_organizations", value: "true"),
      URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "originator", value: profile.originator),
    ]
    guard let authorizationURL = components?.url else {
      throw ChatGPTFailure(.invalidConfiguration)
    }
    return ChatGPTWebAuthorization(
      authorizationURL: authorizationURL,
      expiresAt: Date().addingTimeInterval(Limits.authorizationLifetime),
      redirectURI: redirectURI, state: state, verifier: verifier)
  }

  private static func randomBase64URL(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
      .base64URLEncoded
  }
  #endif
}

#if canImport(CryptoKit) && canImport(Network)
extension Data {
  fileprivate var base64URLEncoded: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
#endif

/// Retains a listener whose explicit stop failed, without retaining raw diagnostics.
struct ChatGPTSignInDrainFailure: Error, Sendable, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
  let completionID = UUID()
  private let cancel: @Sendable () async throws -> Void
  fileprivate init(retaining session: ChatGPTSignInSession) { cancel = session.cancel }
  init(cancel: @escaping @Sendable () async throws -> Void) { self.cancel = cancel }
  var description: String { "ChatGPT sign-in listener could not prove local completion." }
  var debugDescription: String { description }
  var errorDescription: String? { description }
}
