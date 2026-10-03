import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private enum ChatGPTWireLimits {
  static let minimumTransportResponseBytes = 1
  static let supportedMaximumTransportResponseBytes = 48 * 1_024 * 1_024
}

public enum ChatGPTTransportElement: Sendable, Equatable {
  case response(statusCode: Int, headers: [String: String])
  case body(Data)
}

public protocol ChatGPTTransport: Sendable {
  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error>

  /// Returns the stream and the independent local transport settlement boundary.
  /// Throwing before returning must leave no unowned transport work behind.
  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation
}

public extension ChatGPTTransport {
  /// Stream-only implementations remain source compatible for direct stream callers.
  /// Services must not mistake an arbitrary buffered stream's EOF for native completion.
  /// Injected transports opt into managed service execution by implementing invocation.
  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation
  {
    throw ChatGPTFailure(.invalidConfiguration)
  }
}

/// One HTTP operation, not an account/session owner or a remote rollback receipt.
public struct ChatGPTTransportInvocation: Sendable {
  public let events: AsyncThrowingStream<ChatGPTTransportElement, any Error>
  public let cancel: @Sendable () -> Void
  /// Idempotent, cancellation-insensitive join. Request errors travel through events;
  /// this port throws only when local producer/transport settlement cannot be proved.
  public let waitForCompletion: @Sendable () async throws -> Void

  public init(
    events: AsyncThrowingStream<ChatGPTTransportElement, any Error>,
    cancel: @escaping @Sendable () -> Void,
    waitForCompletion: @escaping @Sendable () async throws -> Void
  ) {
    self.events = events
    self.cancel = cancel
    self.waitForCompletion = waitForCompletion
  }

  /// All service consumers use the same cancellation/drain boundary. A parsing error,
  /// rejected HTTP status, or cancelled iterator still joins the owned transport.
  @_spi(Service) public func consuming<Value: Sendable>(
    _ consume: @Sendable (AsyncThrowingStream<ChatGPTTransportElement, any Error>) async throws -> Value
  ) async throws -> Value {
    try await withTaskCancellationHandler {
      let result: Result<Value, any Error>
      do {
        result = .success(try await consume(events))
      } catch {
        cancel()
        result = .failure(error)
      }
      do {
        try await waitForCompletion()
      } catch {
        cancel()
        // Never retry a failed receipt or turn it into an ordinary request failure.
        throw ChatGPTTransportDrainFailure(retaining: self)
      }
      try Task.checkCancellation()
      return try result.get()
    } onCancel: {
      cancel()
    }
  }
}


/// The operation could not prove local producer settlement. This is not a remote
/// service error, is not safely retryable, and contains no credential/response data.
@_spi(Service) public struct ChatGPTTransportDrainFailure: Error, Sendable, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
  // Retain the exact operation when settlement is unproved; never lose ownership
  // while an account/runtime still retains the failure as its quarantine receipt.
  let completionID = UUID()
  private let operation: ChatGPTTransportInvocation
  fileprivate init(retaining operation: ChatGPTTransportInvocation) { self.operation = operation }
  public var description: String { "ChatGPT transport could not prove local completion." }
  public var debugDescription: String { description }
  public var errorDescription: String? { description }
}

/// Production transport. It uses an ephemeral URLSession and rejects redirects so a bearer
/// credential cannot be forwarded to an unintended endpoint. Tests inject the transport.
public struct URLSessionChatGPTTransport: ChatGPTTransport, Sendable {
  public init() {}

  public func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error>
  {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }

  public func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation
  {
    guard (ChatGPTWireLimits.minimumTransportResponseBytes...ChatGPTWireLimits.supportedMaximumTransportResponseBytes).contains(maxResponseBytes) else {
      throw ChatGPTTransportError.limitExceeded
    }
    try Task.checkCancellation()
    return URLSessionChatGPTOperation(maxResponseBytes: maxResponseBytes).start(request)
  }
}

@_spi(Service) public enum ChatGPTTransportError: Error, Sendable, Equatable {
  case limitExceeded
  case invalidResponse
  case duplicateResponse
  case bodyBeforeResponse
  case responseTooLarge
}

/// Native completion receipts can arrive in either order. Neither receipt alone
/// authorizes releasing an operation or reporting a successful local drain.
enum ChatGPTTransportCompletionState {
  enum Boundary { case task, session }
  case pending, taskFinished, sessionInvalidated, settled

  mutating func observe(_ boundary: Boundary) {
    switch (self, boundary) {
    case (.pending, .task): self = .taskFinished
    case (.pending, .session): self = .sessionInvalidated
    case (.taskFinished, .session), (.sessionInvalidated, .task): self = .settled
    default: break // Duplicate callbacks cannot undo completion or finish early.
    }
  }
}

private final class URLSessionChatGPTOperation: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let maxResponseBytes: Int
  private var continuation: AsyncThrowingStream<ChatGPTTransportElement, any Error>.Continuation?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var receivedBytes = 0
  private enum ResponseState { case waiting, accepted, rejectedRedirect }
  private var responseState: ResponseState = .waiting
  private enum State {
    case ready
    case streaming
    case finishing
  }
  private var state: State = .ready
  private var completionState: ChatGPTTransportCompletionState = .pending
  private var completionWaiters: [CheckedContinuation<Void, Never>] = []

  init(maxResponseBytes: Int) { self.maxResponseBytes = maxResponseBytes }

  func start(_ request: URLRequest) -> ChatGPTTransportInvocation {
    let events = AsyncThrowingStream<ChatGPTTransportElement, any Error> { continuation in
      lock.lock()
      precondition(state == .ready, "A transport operation starts exactly once.")
      state = .streaming
      self.continuation = continuation
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      self.session = session
      var request = request
      request.httpShouldHandleCookies = false
      request.cachePolicy = .reloadIgnoringLocalCacheData
      let task = session.dataTask(with: request)
      self.task = task
      let cancelled = Task.isCancelled
      lock.unlock()

      continuation.onTermination = { @Sendable [weak self] termination in
        if case .cancelled = termination { self?.cancel() }
      }
      // Always resume the registered task: cancelling a suspended task is a signal,
      // not proof that its delegate/invalidation callbacks have finished.
      if cancelled { cancel() }
      task.resume()
    }
    return ChatGPTTransportInvocation(
      events: events,
      cancel: { self.cancel() },
      waitForCompletion: { await self.waitForCompletion() }
    )
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    let redirectRejected = responseState == .rejectedRedirect
    lock.unlock()
    if redirectRejected {
      // Returning nil from the redirect delegate makes the 3xx the final response.
      // Let Foundation complete that callback/task before invalidating the session.
      completionHandler(.allow)
      return
    }
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(throwing: ChatGPTTransportError.invalidResponse)
      return
    }
    if response.expectedContentLength > Int64(maxResponseBytes) {
      completionHandler(.cancel)
      finish(throwing: ChatGPTTransportError.responseTooLarge)
      return
    }
    let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
      result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
    }
    lock.lock()
    guard state == .streaming, responseState == .waiting, let continuation else {
      lock.unlock()
      completionHandler(.cancel)
      finish(throwing: ChatGPTTransportError.duplicateResponse)
      return
    }
    responseState = .accepted
    lock.unlock()
    completionHandler(.allow)
    if case .terminated = continuation.yield(
      .response(statusCode: http.statusCode, headers: headers))
    {
      cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // Refuse redirects; allowing URLSession to carry the original request would make the
    // bearer credential's destination depend on a remote response.
    lock.lock()
    responseState = .rejectedRedirect
    lock.unlock()
    completionHandler(nil)
    // No invalidate/cancel here: Foundation still owns the redirect callback.
    // didCompleteWithError will report rejection and then begin session settlement.
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    if responseState == .rejectedRedirect {
      lock.unlock()
      return // Never expose the refused redirect body as service output.
    }
    guard state == .streaming, responseState == .accepted, let continuation else {
      lock.unlock()
      dataTask.cancel()
      finish(throwing: ChatGPTTransportError.bodyBeforeResponse)
      return
    }
    let (next, overflow) = receivedBytes.addingReportingOverflow(data.count)
    guard !overflow, next <= maxResponseBytes else {
      lock.unlock()
      dataTask.cancel()
      finish(throwing: ChatGPTTransportError.responseTooLarge)
      return
    }
    receivedBytes = next
    lock.unlock()
    if case .terminated = continuation.yield(.body(data)) { cancel() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    recordCompletion(.task)
    if let error {
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
        finish(throwing: CancellationError())
      } else {
        finish(throwing: ChatGPTTransportError.invalidResponse)
      }
      return
    }
    lock.lock()
    let hasResponse = responseState == .accepted
    lock.unlock()
    guard hasResponse else {
      finish(throwing: ChatGPTTransportError.invalidResponse)
      return
    }
    finish(throwing: nil)
  }

  private func cancel() {
    finish(throwing: CancellationError())
  }

  /// Logical stream termination. Retain task/session ownership until URLSession's
  /// task-completion and final invalidation callbacks have both been observed.
  private func finish(throwing error: (any Error)?) {
    lock.lock()
    guard state == .streaming else {
      lock.unlock()
      return
    }
    state = .finishing
    let continuation = self.continuation
    self.continuation = nil
    let session = self.session
    let task = self.task
    lock.unlock()
    // Cancel the owned task, then gracefully invalidate. invalidateAndCancel's
    // invalidation callback alone is not a promise that the task has completed.
    if error != nil { task?.cancel() }
    session?.finishTasksAndInvalidate()
    continuation?.finish(throwing: error)
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
    lock.lock()
    state = .finishing
    let continuation = self.continuation
    self.continuation = nil
    let task = self.task
    lock.unlock()
    // Unexpected invalidation must not turn a truncated response into successful EOF.
    if let continuation {
      task?.cancel()
      continuation.finish(throwing: ChatGPTTransportError.invalidResponse)
    }
    recordCompletion(.session)
  }

  private func recordCompletion(_ boundary: ChatGPTTransportCompletionState.Boundary) {
    lock.lock()
    completionState.observe(boundary)
    guard completionState == .settled else { lock.unlock(); return }
    self.task = nil
    self.session = nil
    let waiters = completionWaiters
    completionWaiters.removeAll()
    lock.unlock()
    for waiter in waiters { waiter.resume() }
  }

  private func waitForCompletion() async {
    // Deliberately no Task.checkCancellation: a cancelled owner still has to drain.
    await withCheckedContinuation { continuation in
      lock.lock()
      if completionState == .settled {
        lock.unlock()
        continuation.resume()
      } else {
        completionWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

}

@_spi(Service) public func chatGPTUserAgent(profile: ChatGPTProtocolProfile) -> String {
  #if os(iOS)
    let platform = "iOS"
  #elseif os(macOS)
    let platform = "macOS"
  #else
    let platform = "unknown-os"
  #endif
  #if arch(arm64)
    let architecture = "arm64"
  #elseif arch(x86_64)
    let architecture = "x86_64"
  #else
    let architecture = "unknown-arch"
  #endif
  return "\(profile.originator)/\(profile.clientVersion) (\(platform); \(architecture))"
}

