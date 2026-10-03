import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public actor ChatGPTAccountSession {
  private enum Limits {
    static let tokenRefreshLeeway: TimeInterval = 5 * 60
    static let maximumAuthorizationCodeUTF8Bytes = 16 * 1_024
  }

  private struct SignInPresentation {
    let session: ChatGPTSignInSession
    let generation: UInt64
    var authorization: ChatGPTWebAuthorization { session.authorization }
  }

  private enum SignInState {
    case idle
    case starting(
      generation: UInt64, operation: ChatGPTSharedOperation<ChatGPTWebAuthorization>)
    case presenting(SignInPresentation)
    case completing(SignInPresentation, operation: ChatGPTSharedOperation<ChatGPTAccount>)
    case cancelling(ChatGPTSharedOperation<Void>)
  }

  /// One authority for credential admission; failure is sticky until explicit cleanup.
  private enum CredentialState {
    case ready
    case replacing(authorizationGeneration: UInt64)
    case signingOut(ChatGPTSharedOperation<Void>)
    case signedOut
    case blocked(any Error)
  }

  private var credentialState: CredentialState = .ready
  // Lifetime roots, not a second credential/admission state. Already-admitted
  // operations can fail concurrently; preserving only the latest error loses owners.
  // Failure identity deduplicates repeated cleanup observations. Never auto-release.
  private var unprovedCompletionOwners: [UUID: any Error] = [:]
  private let profile: ChatGPTProtocolProfile
  private let now: @Sendable () -> Date
  private let store: any ChatGPTCredentialStoring
  private let transport: any ChatGPTTransport
  private let startAuthorization: @Sendable (ChatGPTProtocolProfile) async throws -> ChatGPTSignInSession
  private var signInState: SignInState = .idle
  private var authorizationGeneration: UInt64 = 0
  private var refreshTask: ChatGPTSharedOperation<ChatGPTTokenSet>?
  private var refreshOperationID: UInt64 = 0
  private var credentialGeneration: UInt64 = 0

  public init(credentialNamespace: String) throws {
    profile = .codexSubscription
    now = Date.init
    #if canImport(Security)
    store = try ChatGPTKeychainStore(namespace: credentialNamespace)
    transport = URLSessionChatGPTTransport()
    startAuthorization = ChatGPTSignInSession.start
    #else
    // No credential persistence fallback exists on unsupported hosts.
    throw ChatGPTFailure(.invalidConfiguration)
    #endif
  }

  init(
    profile: ChatGPTProtocolProfile,
    store: any ChatGPTCredentialStoring,
    transport: any ChatGPTTransport,
    now: @escaping @Sendable () -> Date = Date.init,
    startAuthorization: @escaping @Sendable (ChatGPTProtocolProfile) async throws -> ChatGPTSignInSession = ChatGPTSignInSession.start
  ) {
    self.profile = profile
    self.store = store
    self.transport = transport
    self.now = now
    self.startAuthorization = startAuthorization
  }

  public func status() throws -> ChatGPTSubscriptionStatus {
    switch credentialState {
    case .signingOut, .signedOut: return .signedOut
    case .blocked(let error): throw error
    case .ready, .replacing: break
    }
    switch signInState {
    case .starting:
      return .signedOut
    case .presenting(let presentation), .completing(let presentation, _):
      return .authorizing(presentation.authorization)
    case .idle, .cancelling:
      break
    }
    guard let token = try store.load() else { return .signedOut }
    return token.expiresAt > now() ? .ready(token.account) : .expired
  }

  public func beginSignIn() async throws -> ChatGPTWebAuthorization {
    while true {
      try await awaitCredentialAdmission()
      try Task.checkCancellation()
      switch signInState {
      case .starting(_, let operation):
        return try await operation.value()
      case .presenting(let presentation), .completing(let presentation, _):
        if presentation.authorization.expiresAt > now() { return presentation.authorization }
        try await cancelSignIn()
      case .cancelling:
        try await cancelSignIn()
      case .idle:
        // A new sign-in ends the completed-logout epoch. Otherwise a second
        // signOut would falsely return before stopping this new listener.
        if case .signedOut = credentialState { credentialState = .ready }
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        let task = Task { [weak self] in
          guard let self else { throw ChatGPTFailure(.signInCancelled) }
          return try await self.startSignIn(generation: generation)
        }
        let operation = ChatGPTSharedOperation(task: task)
        signInState = .starting(generation: generation, operation: operation)
        // A cancelled waiter is not the owner: startSignIn clears this state only
        // after it has stopped any listener it acquired before cancellation.
        return try await operation.value()
      }
      // Cleanup suspended. Re-evaluate instead of starting a second listener.
    }
  }

  public func completeSignIn(
    _ authorization: ChatGPTWebAuthorization
  ) async throws -> ChatGPTAccount {
    try Task.checkCancellation()
    switch credentialState {
    case .signingOut: throw ChatGPTFailure(.signInCancelled)
    case .blocked(let error): throw error
    case .ready, .replacing, .signedOut: break
    }
    switch signInState {
    case .idle:
      throw ChatGPTFailure(.authorizationFailed)
    case .starting:
      throw ChatGPTFailure(.authorizationFailed)
    case .cancelling:
      try await cancelSignIn()
      throw ChatGPTFailure(.signInCancelled)
    case .presenting(let presentation):
      guard presentation.authorization == authorization else {
        throw ChatGPTFailure(.authorizationFailed)
      }
      guard authorization.expiresAt > now() else {
        try await cancelSignIn()
        throw ChatGPTFailure(.authorizationExpired)
      }
      let task = Task { [weak self] in
        guard let self else { throw ChatGPTFailure(.signInCancelled) }
        return try await self.performSignIn(presentation)
      }
      let operation = ChatGPTSharedOperation(task: task)
      signInState = .completing(presentation, operation: operation)
      return try await operation.value()
    case .completing(let presentation, let operation):
      guard presentation.authorization == authorization else {
        throw ChatGPTFailure(.authorizationFailed)
      }
      return try await operation.value()
    }
  }

  public func cancelSignIn() async throws {
    let operation: ChatGPTSharedOperation<Void>
    switch signInState {
    case .idle: return
    case .cancelling(let current): operation = current
    case .starting(_, let signInOperation):
      authorizationGeneration &+= 1
      operation = makeStartingCancellationOperation(signInOperation: signInOperation)
    case .presenting(let presentation):
      authorizationGeneration &+= 1
      operation = makeCancellationOperation(session: presentation.session, signInOperation: nil)
    case .completing(let presentation, let signInOperation):
      authorizationGeneration &+= 1
      operation = makeCancellationOperation(session: presentation.session, signInOperation: signInOperation)
    }
    signInState = .cancelling(operation)
    do { try await operation.result().get() }
    catch {
      blockCredentialAdmission(error)
      throw error
    }
    if case .cancelling(let current) = signInState, current === operation {
      signInState = .idle
      if case .replacing = credentialState { credentialState = .ready }
    }
  }

  /// Logout owns cleanup. Caller cancellation cannot cancel or shorten this join.
  public func signOut() async throws {
    let unproved: (any Error)?
    switch credentialState {
    case .signedOut: return
    case .signingOut(let operation):
      return try await operation.result().get()
    case .blocked(let error):
      unproved = Self.isUnprovedDrain(error) ? error : nil
    case .ready, .replacing: unproved = nil
    }
    // Reserve admission and invalidate snapshots before any suspension point.
    credentialGeneration &+= 1
    authorizationGeneration &+= 1
    let task = Task<Void, any Error> {
      do {
        try await self.performSignOut(unproved: unproved)
        self.credentialState = .signedOut
      } catch {
        self.credentialState = .blocked(error)
        throw error
      }
    }
    let operation = ChatGPTSharedOperation(task: task, cancellationOwnership: .owner)
    credentialState = .signingOut(operation)
    try await operation.result().get()
  }

  private func performSignOut(unproved: (any Error)?) async throws {
    let refresh = refreshTask
    refresh?.cancel()
    var failure: (any Error)? = unproved
    do { try await cancelSignIn() } catch { if failure == nil { failure = error } }
    if let refresh {
      if case .failure(let error) = await refresh.result(), error is ChatGPTTransportDrainFailure {
        retainUnprovedCompletion(error)
        if failure == nil { failure = error }
      }
      if failure == nil, refreshTask === refresh { refreshTask = nil }
    }
    // Revocation is attempted even when another cleanup boundary failed.
    do { try store.delete() } catch { if failure == nil { failure = error } }
    // A service request admitted before logout may fail while auth cleanup awaits.
    if failure == nil { failure = unprovedCompletionOwners.values.first }
    if let failure { throw failure }
  }

  private func awaitCredentialAdmission() async throws {
    while true {
      try Task.checkCancellation()
      switch credentialState {
      case .ready, .signedOut: return
      case .blocked(let error): throw error
      case .signingOut(let operation): _ = try await operation.value()
      case .replacing:
        guard case .completing(_, let operation) = signInState else {
          throw ChatGPTFailure(.signInRequired)
        }
        _ = try await operation.value()
      }
    }
  }

  func access(forceRefresh: Bool = false) async throws -> ChatGPTTokenSet {
    try await awaitCredentialAdmission()
    try Task.checkCancellation()
    // A retained unproved drain may not be bypassed by the fresh-token fast path.
    if let refreshTask { return try await refreshValue(refreshTask) }
    guard let current = try store.load() else { throw ChatGPTFailure(.signInRequired) }
    try current.validate()
    if !forceRefresh, current.expiresAt.timeIntervalSince(now()) > Limits.tokenRefreshLeeway { return current }
    let staleRefresh = current.refreshToken
    let generation = credentialGeneration
    let task = Task { [profile, transport] in
      let endpoint = try profile.issuer.appendingValidated(path: "oauth/token")
      let body = try chatGPTJSONData([
        "client_id": profile.clientID,
        "grant_type": "refresh_token",
        "refresh_token": staleRefresh,
      ])
      let response = try await Self.sendJSON(
        transport: transport, method: "POST", url: endpoint, body: body,
        contentType: "application/json", authorization: nil)
      guard response.statusCode == 200 else {
        let permanent = Self.isPermanentRefreshRejection(response)
        if permanent, try self.currentRefreshToken() == staleRefresh {
          try self.deleteCredentialIfCurrent(generation: generation, refreshToken: staleRefresh)
        }
        throw ChatGPTFailure(permanent ? .tokenRefreshFailed : .tokenRefreshUnavailable)
      }
      let refreshed = try Self.parseTokenResponse(response.body, preserving: current, now: self.now())
      return try self.commitRefresh(
        refreshed, generation: generation, refreshToken: staleRefresh)
    }
    refreshOperationID &+= 1
    let operationID = refreshOperationID
    let operation = ChatGPTSharedOperation(task: task)
    refreshTask = operation
    Task { [weak self] in
      let result = await task.result
      await self?.finishRefresh(operationID: operationID, result: result)
    }
    return try await refreshValue(operation)
  }

  private func refreshValue(_ operation: ChatGPTSharedOperation<ChatGPTTokenSet>) async throws -> ChatGPTTokenSet {
    let generation = credentialGeneration
    do {
      let token = try await operation.value()
      guard generation == credentialGeneration, case .ready = credentialState else {
        throw ChatGPTFailure(.signInRequired)
      }
      return token
    } catch let error as ChatGPTTransportDrainFailure {
      blockCredentialAdmission(error)
      throw error
    }
  }

  private func retainUnprovedCompletion(_ error: any Error) {
    if let failure = error as? ChatGPTTransportDrainFailure {
      unprovedCompletionOwners[failure.completionID] = failure
    } else if let failure = error as? ChatGPTSignInDrainFailure {
      unprovedCompletionOwners[failure.completionID] = failure
    }
  }

  private func blockCredentialAdmission(_ error: any Error) {
    retainUnprovedCompletion(error)
    // An older continuation must never replace a newer logout's cleanup owner.
    if case .signingOut = credentialState { return }
    if case .blocked(let previous) = credentialState, Self.isUnprovedDrain(previous) { return }
    credentialState = .blocked(error)
  }

  private func startSignIn(generation: UInt64) async throws -> ChatGPTWebAuthorization {
    var started: ChatGPTSignInSession?
    do {
      let session = try await startAuthorization(profile)
      started = session
      try Task.checkCancellation()
      guard generation == authorizationGeneration,
        case .starting(let currentGeneration, _) = signInState,
        currentGeneration == generation
      else { throw ChatGPTFailure(.signInCancelled) }
      signInState = .presenting(SignInPresentation(session: session, generation: generation))
      started = nil
      return session.authorization
    } catch {
      if Self.isUnprovedDrain(error) {
        blockCredentialAdmission(error)
        throw error
      }
      if let started {
        do { try await started.stop() }
        catch {
          blockCredentialAdmission(error)
          throw error
        }
      }
      if case .starting(let current, _) = signInState, current == generation {
        signInState = .idle
      }
      throw error
    }
  }

  private func performSignIn(_ presentation: SignInPresentation) async throws -> ChatGPTAccount {
    defer {
      finishSignIn(
        generation: presentation.generation, authorization: presentation.authorization)
    }
    let callbackURL: URL
    do {
      callbackURL = try await presentation.session.waitForCallback(presentation.authorization.expiresAt)
    } catch {
      let callbackFailure = error
      do { try await presentation.session.stop() }
      catch {
        blockCredentialAdmission(error)
        throw error
      }
      throw callbackFailure
    }
    try Task.checkCancellation()
    let code = try Self.authorizationCode(
      from: callbackURL, matching: presentation.authorization)
    let token: ChatGPTTokenSet
    do {
      token = try await exchangeCode(
        code: code,
        verifier: presentation.authorization.verifier,
        redirectURI: presentation.authorization.redirectURI)
    } catch let error as ChatGPTTransportDrainFailure {
      blockCredentialAdmission(error)
      throw error
    }
    try Task.checkCancellation()
    guard presentation.generation == authorizationGeneration,
      case .completing(let current, _) = signInState,
      current.authorization == presentation.authorization
    else { throw ChatGPTFailure(.signInCancelled) }
    credentialState = .replacing(authorizationGeneration: presentation.generation)
    credentialGeneration &+= 1
    let refresh = refreshTask
    refresh?.cancel()
    if let refresh {
      if case .failure(let error) = await refresh.result(), error is ChatGPTTransportDrainFailure {
        blockCredentialAdmission(error)
        throw error
      }
    }
    try Task.checkCancellation()
    guard presentation.generation == authorizationGeneration,
      case .replacing(let generation) = credentialState,
      generation == presentation.generation
    else { throw ChatGPTFailure(.signInCancelled) }
    if refreshTask === refresh { refreshTask = nil }
    refreshOperationID &+= 1
    do { try store.save(token) }
    catch {
      credentialState = .blocked(error)
      throw error
    }
    credentialState = .ready
    return token.account
  }

  private func finishSignIn(
    generation: UInt64,
    authorization: ChatGPTWebAuthorization
  ) {
    guard generation == authorizationGeneration,
      case .completing(let presentation, _) = signInState,
      presentation.authorization == authorization
    else { return }
    if case .replacing(let current) = credentialState, current == generation {
      credentialState = .ready
    }
    if case .blocked = credentialState { return }
    signInState = .idle
  }

  private func makeCancellationOperation(
    session: ChatGPTSignInSession,
    signInOperation: ChatGPTSharedOperation<ChatGPTAccount>?
  ) -> ChatGPTSharedOperation<Void> {
    let task = Task<Void, any Error> {
      signInOperation?.cancel()
      var cleanupFailure: (any Error)?
      do {
        try await session.stop()
      } catch {
        cleanupFailure = error
      }
      if let signInOperation {
        do {
          _ = try await signInOperation.result().get()
        } catch is CancellationError {
          // The operation was explicitly cancelled above.
        } catch let failure as ChatGPTFailure where failure.code == .signInCancelled {
          // The generation guard reports the expected cancellation outcome.
        } catch {
          if Self.isUnprovedDrain(error), cleanupFailure == nil { cleanupFailure = error }
        }
      }
      if let cleanupFailure { throw cleanupFailure }
    }
    return ChatGPTSharedOperation(task: task, cancellationOwnership: .owner)
  }

  private func makeStartingCancellationOperation(
    signInOperation: ChatGPTSharedOperation<ChatGPTWebAuthorization>
  ) -> ChatGPTSharedOperation<Void> {
    let task = Task<Void, any Error> {
      signInOperation.cancel()
      do {
        _ = try await signInOperation.result().get()
      } catch is CancellationError {
        // Explicit cancellation is the expected outcome of the starting operation.
      } catch let failure as ChatGPTFailure where failure.code == .signInCancelled {
        // The generation guard reports the expected cancellation outcome.
      } catch {
        if Self.isUnprovedDrain(error) { throw error }
      }
    }
    return ChatGPTSharedOperation(task: task, cancellationOwnership: .owner)
  }

  private static func isUnprovedDrain(_ error: any Error) -> Bool {
    error is ChatGPTTransportDrainFailure || error is ChatGPTSignInDrainFailure
  }

  private func finishRefresh(operationID: UInt64, result: Result<ChatGPTTokenSet, any Error>) {
    guard operationID == refreshOperationID else { return }
    if case .failure(let error) = result, error is ChatGPTTransportDrainFailure {
      // Retain the owner and block future authenticated work; deletion is not a drain receipt.
      blockCredentialAdmission(error)
      return
    }
    if case .replacing = credentialState { return }
    refreshTask = nil
  }

  /// Service SPI exposes an access-token snapshot, never a refresh token or ID token.
  @_spi(Service) public func requestAuthorization(
    forceRefresh: Bool = false
  ) async throws -> ChatGPTRequestAuthorization {
    let generation = credentialGeneration
    let token = try await access(forceRefresh: forceRefresh)
    guard generation == credentialGeneration else { throw ChatGPTFailure(.signInRequired) }
    try Task.checkCancellation()
    return ChatGPTRequestAuthorization(
      accessToken: token.accessToken,
      accountID: token.account.accountID,
      credentialGeneration: credentialGeneration, profile: profile)
  }

  /// Account replacement/sign-out invalidates derived catalog state and authenticated retries.
  @_spi(Service) public func validateAuthorization(
    _ authorization: ChatGPTRequestAuthorization
  ) throws {
    switch credentialState {
    case .ready: break
    case .blocked(let error): throw error
    case .replacing, .signingOut, .signedOut: throw ChatGPTFailure(.signInRequired)
    }
    guard authorization.credentialGeneration == credentialGeneration,
      try store.load()?.account.accountID == authorization.accountID
    else { throw ChatGPTFailure(.signInRequired) }
  }

  /// Bounded authenticated GET mechanism. Endpoint choice and payload semantics belong to callers.
  @_spi(Service) public func authenticatedGET(to url: URL) async throws
    -> ChatGPTAuthenticatedResponse
  {
    try profile.validateServiceEndpoint(url)
    let generation = credentialGeneration
    var token = try await access()
    guard generation == credentialGeneration else { throw ChatGPTFailure(.signInRequired) }
    let authorization = ChatGPTRequestAuthorization(
      accessToken: token.accessToken, accountID: token.account.accountID,
      credentialGeneration: generation, profile: profile)
    let initialAuthorization = authorization
    for attempt in 0..<ChatGPTSubscriptionRetryPolicy.authenticationAttemptCount {
      try Task.checkCancellation()
      try validateAuthorization(initialAuthorization)
      let response = try await sendJSON(
        method: "GET", url: url, body: nil, authorization: token)
      if response.statusCode == 401,
        ChatGPTSubscriptionRetryPolicy.permitsAuthenticationRefresh(after: attempt)
      {
        try validateAuthorization(initialAuthorization)
        token = try await access(forceRefresh: true)
        try validateAuthorization(initialAuthorization)
        continue
      }
      try Task.checkCancellation()
      try validateAuthorization(initialAuthorization)
      return ChatGPTAuthenticatedResponse(
        statusCode: response.statusCode, body: response.body, authorization: authorization)
    }
    throw ChatGPTFailure(.signInRequired)
  }

  @_spi(Service) public func protocolProfile() -> ChatGPTProtocolProfile { profile }

  private func currentRefreshToken() throws -> String? { try store.load()?.refreshToken }

  private func commitRefresh(
    _ token: ChatGPTTokenSet,
    generation: UInt64,
    refreshToken: String
  ) throws -> ChatGPTTokenSet {
    guard generation == credentialGeneration,
      try store.load()?.refreshToken == refreshToken
    else { throw ChatGPTFailure(.signInRequired) }
    do { try store.save(token) }
    catch {
      blockCredentialAdmission(error)
      throw error
    }
    return token
  }

  private func deleteCredentialIfCurrent(generation: UInt64, refreshToken: String) throws {
    guard generation == credentialGeneration,
      try store.load()?.refreshToken == refreshToken
    else { return }
    credentialGeneration &+= 1
    do { try store.delete() }
    catch {
      blockCredentialAdmission(error)
      throw error
    }
  }

  private func exchangeCode(
    code: String,
    verifier: String,
    redirectURI: URL
  ) async throws -> ChatGPTTokenSet {
    let endpoint = try profile.issuer.appendingValidated(path: "oauth/token")
    let fields = [
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": redirectURI.absoluteString,
      "client_id": profile.clientID,
      "code_verifier": verifier,
    ]
    let encodedFields = try fields.sorted(by: { $0.key < $1.key }).map { field in
      "\(try field.key.formEncoded())=\(try field.value.formEncoded())"
    }
    let body = Data(encodedFields.joined(separator: "&").utf8)
    let response = try await Self.sendJSON(
      transport: transport, method: "POST", url: endpoint, body: body,
      contentType: "application/x-www-form-urlencoded", authorization: nil)
    guard response.statusCode == 200 else {
      throw Self.mappedStatus(response.statusCode, authorization: true)
    }
    return try Self.parseTokenResponse(response.body, preserving: nil, now: now())
  }

  private func sendJSON(
    method: String,
    url: URL,
    body: Data?,
    authorization: ChatGPTTokenSet?
  ) async throws -> ChatGPTHTTPResponse {
    do {
      return try await Self.sendJSON(
        transport: transport, method: method, url: url, body: body,
        contentType: "application/json", authorization: authorization)
    } catch let error as ChatGPTTransportDrainFailure {
      blockCredentialAdmission(error)
      throw error
    }
  }

  private static func sendJSON(
    transport: any ChatGPTTransport,
    method: String,
    url: URL,
    body: Data?,
    contentType: String,
    authorization: ChatGPTTokenSet?
  ) async throws -> ChatGPTHTTPResponse {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = body
    if let authorization {
      request.setValue("Bearer \(authorization.accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue(authorization.account.accountID, forHTTPHeaderField: "Chatgpt-Account-Id")
    }
    do {
      try Task.checkCancellation()
      let operation = try await transport.invocation(
        request, maxResponseBytes: ChatGPTAccountPayload.maximumResponseBytes)
      return try await operation.consuming { stream in
        var status: Int?
        var data = Data()
        for try await element in stream {
          try Task.checkCancellation()
          switch element {
          case .response(let value, _):
            guard status == nil, (100...599).contains(value) else {
              throw ChatGPTFailure(.malformedResponse)
            }
            status = value
          case .body(let chunk):
            let (next, overflow) = data.count.addingReportingOverflow(chunk.count)
            guard status != nil, !overflow, next <= ChatGPTAccountPayload.maximumResponseBytes else {
              throw ChatGPTFailure(.malformedResponse)
            }
            data.append(chunk)
          }
        }
        try Task.checkCancellation()
        guard let status else { throw ChatGPTFailure(.malformedResponse) }
        return ChatGPTHTTPResponse(statusCode: status, body: data)
      }
    } catch let failure as ChatGPTTransportDrainFailure { throw failure }
    catch is CancellationError { throw CancellationError() }
    catch let failure as ChatGPTFailure { throw failure }
    catch { throw ChatGPTFailure(.transportFailure) }
  }

  private static func parseTokenResponse(
    _ data: Data,
    preserving previous: ChatGPTTokenSet?,
    now: Date
  ) throws -> ChatGPTTokenSet {
    let root = try ChatGPTAccountPayload.object(data)
    guard let access = root["access_token"] as? String,
      let id = (root["id_token"] as? String) ?? previous?.idToken,
      let refresh = (root["refresh_token"] as? String) ?? previous?.refreshToken,
      ChatGPTValidation.tokenLike(
        access, maxBytes: ChatGPTCredentialLimits.maximumTokenUTF8Bytes),
      ChatGPTValidation.tokenLike(
        id, maxBytes: ChatGPTCredentialLimits.maximumTokenUTF8Bytes),
      ChatGPTValidation.tokenLike(
        refresh, maxBytes: ChatGPTCredentialLimits.maximumTokenUTF8Bytes)
    else { throw ChatGPTFailure(.malformedResponse) }
    let expires = try ChatGPTClaims.expiration(
      accessToken: access,
      expiresIn: (root["expires_in"] as? NSNumber)?.doubleValue, now: now)
    let account: ChatGPTAccount
    if root["id_token"] == nil, let previous {
      account = previous.account
    } else {
      account = try ChatGPTClaims.account(idToken: id)
    }
    let token = ChatGPTTokenSet(
      accessToken: access,
      refreshToken: refresh,
      idToken: id,
      expiresAt: expires,
      account: account
    )
    try token.validate()
    return token
  }

  private static func authorizationCode(
    from callbackURL: URL,
    matching authorization: ChatGPTWebAuthorization
  ) throws -> String {
    guard callbackURL.scheme?.lowercased() == authorization.redirectURI.scheme?.lowercased(),
      callbackURL.host?.lowercased() == authorization.redirectURI.host?.lowercased(),
      callbackURL.port == authorization.redirectURI.port,
      callbackURL.path == authorization.redirectURI.path,
      callbackURL.user == nil, callbackURL.password == nil,
      callbackURL.fragment == nil,
      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    else { throw ChatGPTFailure(.authorizationFailed) }
    let values = Dictionary(grouping: components.queryItems ?? [], by: \.name)
    guard values.values.allSatisfy({ $0.count == 1 }) else {
      throw ChatGPTFailure(.authorizationFailed)
    }
    if values["error"]?.first?.value != nil {
      throw ChatGPTFailure(.signInCancelled)
    }
    guard values["state"]?.first?.value == authorization.state,
      let code = values["code"]?.first?.value,
      ChatGPTValidation.tokenLike(code, maxBytes: Limits.maximumAuthorizationCodeUTF8Bytes)
    else { throw ChatGPTFailure(.authorizationFailed) }
    return code
  }

  private static func mappedStatus(_ status: Int, authorization: Bool) -> ChatGPTFailure {
    if status == 429 { return ChatGPTFailure(.rateLimited) }
    if authorization, (400...499).contains(status) {
      return ChatGPTFailure(.authorizationFailed)
    }
    if status == 401 || status == 403 { return ChatGPTFailure(.signInRequired) }
    if (400...599).contains(status) { return ChatGPTFailure(.serviceRejected) }
    return ChatGPTFailure(.malformedResponse)
  }

  private static func isPermanentRefreshRejection(_ response: ChatGPTHTTPResponse) -> Bool {
    if response.statusCode == 401 { return true }
    // OAuth invalid_grant is a permanent grant failure, not a transient outage.
    // Never invalidate credentials based on a 429/5xx response body's error text.
    guard response.statusCode == 400 || response.statusCode == 403 else { return false }
    guard let root = try? ChatGPTAccountPayload.object(response.body) else { return false }
    let error = root["error"] as? [String: Any]
    let code = (root["error"] as? String) ?? (error?["code"] as? String) ?? (root["code"] as? String)
    return ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"]
      .contains(code)
  }
}

private struct ChatGPTHTTPResponse: Sendable {
  let statusCode: Int
  let body: Data
}

private enum ChatGPTValidation {
  static func tokenLike(_ value: String, maxBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maxBytes
      && !value.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F })
  }


}

extension URL {
  func appendingValidated(path: String) throws -> URL {
    guard !path.isEmpty, path.utf8.count <= 1_024,
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { throw ChatGPTFailure(.invalidConfiguration) }
    return path.split(separator: "/").reduce(self) { $0.appendingPathComponent(String($1)) }
  }

}

extension String {
  fileprivate func formEncoded() throws -> String {
    let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let encoded = addingPercentEncoding(withAllowedCharacters: unreserved) else {
      throw ChatGPTFailure(.invalidConfiguration)
    }
    return encoded
  }
}

private func chatGPTJSONData(_ object: Any) throws -> Data {
  guard JSONSerialization.isValidJSONObject(object) else {
    throw ChatGPTFailure(.invalidConfiguration)
  }
  return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}


/// An opaque credential-epoch lease. Construction remains Account-owned.
@_spi(Service) public struct ChatGPTRequestAuthorization: Sendable {
  fileprivate let accessToken: String
  fileprivate let accountID: String
  fileprivate let credentialGeneration: UInt64
  fileprivate let profile: ChatGPTProtocolProfile

  public func apply(to request: inout URLRequest) throws {
    guard let url = request.url else { throw ChatGPTFailure(.invalidConfiguration) }
    try profile.validateServiceEndpoint(url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(accountID, forHTTPHeaderField: "Chatgpt-Account-Id")
  }
}

@_spi(Service) public struct ChatGPTAuthenticatedResponse: Sendable {
  public let statusCode: Int
  public let body: Data
  public let authorization: ChatGPTRequestAuthorization
}
