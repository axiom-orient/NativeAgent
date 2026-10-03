#if canImport(Network)
import Dispatch
import Foundation
import Network

/// One IPv4 loopback listener. All mutable state and Network callbacks belong to `queue`.
/// `@unchecked Sendable` is limited to this queue-confined I/O adapter; no UI work occurs here.
/// Completion requires the listener, every accepted connection AND every submitted I/O callback.
final class ChatGPTLocalhostCallbackServer: @unchecked Sendable {
  static let registeredPorts = ChatGPTProtocolProfile.registeredCallbackPorts

  let port: UInt16
  let redirectURI: URL

  private enum Delivery: Sendable {
    case result(Result<URL, any Error>)
    case rejected(any Error)
  }
  private enum Waiter {
    case available
    case waiting(UUID, CheckedContinuation<Delivery, Never>)
    case consumed(UUID)

    var id: UUID? {
      switch self {
      case .available: nil
      case .waiting(let id, _), .consumed(let id): id
      }
    }
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "com.openai.nativeagent.localhost-callback")
  private var state = ChatGPTCallbackState<NWConnection>()
  private var startID: UUID?
  private var startContinuation: CheckedContinuation<Void, any Error>?
  private var waiter: Waiter = .available
  private var outcome: Result<URL, any Error>?
  private var shutdownContinuations: [CheckedContinuation<Void, any Error>] = []
  private var shutdownFailure: (any Error)?
  private var callbackDeadline: DispatchWorkItem?
  private var shutdownDeadline: DispatchWorkItem?

  init(port: UInt16) throws {
    guard Self.registeredPorts.contains(port), let endpointPort = NWEndpoint.Port(rawValue: port) else {
      throw ChatGPTFailure(.invalidConfiguration)
    }
    self.port = port
    redirectURI = try ChatGPTProtocolProfile.callbackRedirectURI(port: port)
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
    parameters.allowLocalEndpointReuse = false
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.accept(connection)
    }
    listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }
  }

  func start() async throws {
    try Task.checkCancellation()
    let cancellation = CallbackCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        queue.async { [self] in
          guard !cancellation.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
          }
          guard self.state.start() else {
            continuation.resume(throwing: ChatGPTLocalhostCallbackError.alreadyStarted)
            return
          }
          self.startID = id
          self.startContinuation = continuation
          self.listener.start(queue: self.queue)
        }
      }
    } onCancel: {
      cancellation.cancel()
      self.queue.async { [self] in
        guard self.startID == id else { return }
        self.finish(.failure(CancellationError()))
      }
    }
    try Task.checkCancellation()
  }

  /// A cancelled waiter still joins cleanup; an unrelated second waiter never cancels the owner.
  func waitForCallback(until expiration: Date) async throws -> URL {
    let id = UUID()
    let cancellation = CallbackCancellation()
    let delivery = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard case .available = self.waiter else {
            continuation.resume(returning: Delivery.rejected(ChatGPTLocalhostCallbackError.callbackAlreadyConsumed))
            return
          }
          guard self.outcome != nil || self.state.phase == .running else {
            continuation.resume(returning: Delivery.rejected(ChatGPTLocalhostCallbackError.callbackAlreadyConsumed))
            return
          }
          self.waiter = .waiting(id, continuation)
          if cancellation.isCancelled {
            self.finish(.failure(CancellationError()))
            self.cancelConnections()
          } else if let outcome = self.outcome {
            self.deliver(outcome)
          } else {
            let interval = expiration.timeIntervalSinceNow
            guard interval.isFinite, interval > 0 else {
              self.finish(.failure(ChatGPTLocalhostCallbackError.authorizationTimedOut))
              return
            }
            let deadline = DispatchWorkItem { [weak self] in
              self?.finish(.failure(ChatGPTLocalhostCallbackError.authorizationTimedOut))
            }
            self.callbackDeadline = deadline
            self.queue.asyncAfter(deadline: .now() + interval, execute: deadline)
          }
          // A callback can have resolved before this waiter was installed.
          if let outcome = self.outcome { self.deliver(outcome) }
        }
      }
    } onCancel: {
      cancellation.cancel()
      self.queue.async { [self] in
        guard self.waiter.id == id else { return }
        self.finish(.failure(CancellationError()))
        self.cancelConnections()
      }
    }
    switch delivery {
    case .rejected(let error): throw error
    case .result(let result):
      try await waitForShutdown()
      try Task.checkCancellation()
      return try result.get()
    }
  }

  /// Cancellation is a signal; this method does not return success before all receipts arrive.
  /// A missing receipt times out as a sticky failure, never a synthesized completion.
  func cancel() async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        self.finish(.failure(CancellationError()))
        self.cancelConnections()
        self.joinShutdown(continuation)
      }
    }
  }

  // Internal diagnostic used by the native qualification to observe actual accepted connections.
  func activeConnectionCount() async -> Int {
    await withCheckedContinuation { continuation in
      queue.async { [self] in continuation.resume(returning: self.state.connectionCount) }
    }
  }

  static func isAddressInUse(_ error: any Error) -> Bool {
    if let networkError = error as? NWError, case .posix(let code) = networkError { return code == .EADDRINUSE }
    if let posixError = error as? POSIXError { return posixError.code == .EADDRINUSE }
    return false
  }

  static func bindAndStart() async throws -> ChatGPTLocalhostCallbackServer {
    try await bindAndStart(makeServer: { try ChatGPTLocalhostCallbackServer(port: $0) })
  }

  /// Preserve the registered-port order. Only a typed EADDRINUSE admits the next candidate,
  /// and an acquired candidate must be drained first.
  static func bindAndStart(
    makeServer: (UInt16) throws -> ChatGPTLocalhostCallbackServer
  ) async throws -> ChatGPTLocalhostCallbackServer {
    for port in registeredPorts {
      try Task.checkCancellation()
      let server: ChatGPTLocalhostCallbackServer
      do { server = try makeServer(port) }
      catch {
        guard isAddressInUse(error) else { throw error }
        continue
      }
      do {
        try await server.start()
        return server
      } catch {
        let startupFailure = error
        do { try await server.cancel() }
        catch { throw ChatGPTSignInDrainFailure(cancel: { try await server.cancel() }) }
        guard isAddressInUse(startupFailure) else { throw startupFailure }
      }
    }
    throw ChatGPTLocalhostCallbackError.callbackPortsOccupied
  }

  private func accept(_ connection: NWConnection) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard state.track(connection) else { connection.cancel(); return }
    connection.stateUpdateHandler = { [weak self, weak connection] update in
      guard let self, let connection else { return }
      dispatchPrecondition(condition: .onQueue(self.queue))
      switch update {
      case .cancelled:
        self.state.connectionCancelled(connection)
        self.resolveShutdownIfSettled()
      case .failed(let error), .waiting(let error):
        self.cancelConnection(connection)
        self.finish(.failure(error))
      default: break
      }
    }
    connection.start(queue: queue)
    guard state.phase == .running, outcome == nil, Self.isLoopback(connection.endpoint) else {
      cancelConnection(connection)
      return
    }
    guard state.connectionCount <= ChatGPTCallbackPolicy.maximumConcurrentRequests else {
      finish(.failure(ChatGPTLocalhostCallbackError.invalidRequest))
      return
    }
    receive(on: connection, buffer: Data())
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    dispatchPrecondition(condition: .onQueue(queue))
    let operation = UUID()
    guard state.beginIO(on: connection, id: operation) else { return }
    connection.receive(minimumIncompleteLength: 1,
      maximumLength: ChatGPTCallbackPolicy.maximumRequestBytes - buffer.count) { [weak self] data, _, complete, error in
      guard let self else { return }
      dispatchPrecondition(condition: .onQueue(self.queue))
      guard self.state.completeIO(on: connection, id: operation) else { return }
      defer { self.resolveShutdownIfSettled() }
      guard self.state.phase == .running, self.outcome == nil else { return }
      var request = buffer
      if let data { request.append(data) }
      switch ChatGPTCallbackRequest.parse(request, matching: self.redirectURI) {
      case .callback(let callback): self.respond(on: connection, result: .success(callback))
      case .invalid: self.respond(on: connection, result: .failure(ChatGPTLocalhostCallbackError.invalidRequest))
      case .incomplete:
        if complete || error != nil {
          self.respond(on: connection, result: .failure(ChatGPTLocalhostCallbackError.invalidRequest))
        } else {
          self.receive(on: connection, buffer: request)
        }
      }
    }
  }

  private func respond(on connection: NWConnection, result: Result<URL, any Error>) {
    dispatchPrecondition(condition: .onQueue(queue))
    let operation = UUID()
    guard outcome == nil, state.beginIO(on: connection, id: operation, response: true) else {
      cancelConnection(connection)
      return
    }
    let status: String
    let body: String
    switch result {
    case .success:
      status = "200 OK"
      body = "Sign-in callback received. You can return to the app."
    case .failure:
      status = "400 Bad Request"
      body = "Invalid sign-in callback."
    }
    let response = Data(("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
      + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n" + body).utf8)
    connection.send(content: response, completion: .contentProcessed { [weak self] _ in
      guard let self else { return }
      dispatchPrecondition(condition: .onQueue(self.queue))
      guard self.state.completeIO(on: connection, id: operation) else { return }
      self.cancelConnection(connection)
      self.resolveShutdownIfSettled()
    })
    // Let the selected HTTP response finish. All other accepted connections are cancelled now.
    // The drain deadline also bounds this send; send failure is not proof of native cancellation.
    finish(result, preservingResponse: connection)
  }

  private func finish(_ result: Result<URL, any Error>, preservingResponse: NWConnection? = nil) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard outcome == nil else { return }
    outcome = result
    callbackDeadline?.cancel()
    callbackDeadline = nil
    deliver(result)
    if case .failure(let error) = result { resolveStart(.failure(error)) }
    let cancelListener = state.stopListener()
    cancelConnections(preservingResponse: preservingResponse)
    if cancelListener { listener.cancel() }
    if !state.isDrained {
      let deadline = DispatchWorkItem { [weak self] in
        guard let self, !self.state.isDrained else { return }
        self.shutdownFailure = ChatGPTLocalhostCallbackError.shutdownTimedOut
        self.cancelConnections()
        self.resolveShutdownIfSettled()
      }
      shutdownDeadline = deadline
      queue.asyncAfter(deadline: .now() + ChatGPTCallbackPolicy.shutdownTimeout, execute: deadline)
    }
    resolveShutdownIfSettled()
  }

  private func handle(_ update: NWListener.State) {
    dispatchPrecondition(condition: .onQueue(queue))
    switch update {
    case .ready:
      guard state.phase == .starting else { return }
      guard listener.port?.rawValue == port else {
        finish(.failure(ChatGPTFailure(.invalidConfiguration)))
        return
      }
      if state.ready() { resolveStart(.success(())) }
    case .waiting(let error), .failed(let error):
      finish(.failure(error))
    case .cancelled:
      // Unexpected cancellation still terminates any pending callback and start waiter.
      finish(.failure(CancellationError()))
      state.listenerCancelled()
      resolveStart(.failure(CancellationError()))
      resolveShutdownIfSettled()
    case .setup: break
    @unknown default: finish(.failure(ChatGPTFailure(.invalidConfiguration)))
    }
  }

  private func deliver(_ result: Result<URL, any Error>) {
    guard case .waiting(let id, let continuation) = waiter else { return }
    waiter = .consumed(id)
    continuation.resume(returning: .result(result))
  }

  private func cancelConnection(_ connection: NWConnection) {
    state.cancel(connection)?.cancel()
  }

  private func cancelConnections(preservingResponse: NWConnection? = nil) {
    state.cancelConnections(preserving: preservingResponse).forEach { $0.cancel() }
  }

  private func waitForShutdown() async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in self.joinShutdown(continuation) }
    }
  }

  private func joinShutdown(_ continuation: CheckedContinuation<Void, any Error>) {
    if let shutdownFailure { continuation.resume(throwing: shutdownFailure) }
    else if state.isDrained { continuation.resume() }
    else { shutdownContinuations.append(continuation) }
  }

  private func resolveStart(_ result: Result<Void, any Error>) {
    guard let continuation = startContinuation else { return }
    startContinuation = nil
    continuation.resume(with: result)
  }

  private func resolveShutdownIfSettled() {
    guard state.isDrained || shutdownFailure != nil else { return }
    shutdownDeadline?.cancel()
    shutdownDeadline = nil
    let result: Result<Void, any Error> = shutdownFailure.map(Result.failure) ?? .success(())
    let continuations = shutdownContinuations
    shutdownContinuations.removeAll()
    continuations.forEach { $0.resume(with: result) }
  }

  private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
    guard case let .hostPort(host, _) = endpoint, case .ipv4(let address) = host else { return false }
    return address.isLoopback
  }
}

/// The cancellation handler can run before queue registration; this flag closes that race.
/// All other operation state remains exclusively on the callback queue.
private final class CallbackCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() { lock.withLock { cancelled = true } }
}
#endif
