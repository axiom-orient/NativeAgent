#if canImport(Network) && canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import ChatGPTAccount

// These tests use real loopback sockets. They are not compiled or counted on Linux.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CallbackNativeTests {
  @Test("A callback is one-shot and cleanup permits an immediate rebind")
  func callbackAndRebind() async throws {
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    let requestURL = server.redirectURI.appending(
      queryItems: [
        URLQueryItem(name: "code", value: "fixture"),
        URLQueryItem(name: "state", value: "fixture"),
      ])
    let waiting = Task { try await server.waitForCallback(until: Date().addingTimeInterval(5)) }
    var request = URLRequest(url: requestURL)
    request.timeoutInterval = 3
    let (_, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(try await waiting.value == requestURL)
    try await server.cancel()

    let rebound = try ChatGPTLocalhostCallbackServer(port: server.port)
    try await rebound.start()
    try await rebound.cancel()
  }

  @Test("A callback delivered before the waiter is installed is not lost")
  func callbackPendingResultIsDeliveredAtomically() async throws {
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    let callback = server.redirectURI.appending(
      queryItems: [
        URLQueryItem(name: "code", value: "pending"),
        URLQueryItem(name: "state", value: "pending"),
      ])
    var request = URLRequest(url: callback)
    request.timeoutInterval = 3
    let (_, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)

    let received = try await server.waitForCallback(until: Date().addingTimeInterval(5))
    #expect(received.query?.contains("code=pending") == true)
    try await server.cancel()
  }

  @Test("Repeated start, cancel, and rebind cycles keep ownership serialized")
  func repeatedLifecycle() async throws {
    for _ in 0..<3 {
      let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
      try await server.cancel()
    }
  }

  @Test("Cancellation during startup and callback wait is observable and cleaned up")
  func cancellationDuringStartAndWait() async throws {
    let port = try await availableTestPort()
    let starting = try ChatGPTLocalhostCallbackServer(port: port)
    let startTask = Task { try await starting.start() }
    startTask.cancel()
    try await starting.cancel()
    await #expect(throws: (any Error).self) { try await startTask.value }

    let waiting = try ChatGPTLocalhostCallbackServer(port: port)
    try await waiting.start()
    let callbackTask = Task { try await waiting.waitForCallback(until: Date().addingTimeInterval(30)) }
    callbackTask.cancel()
    await #expect(throws: (any Error).self) { try await callbackTask.value }
    try await waiting.cancel()

    let rebound = try ChatGPTLocalhostCallbackServer(port: port)
    try await rebound.start()
    try await rebound.cancel()
  }

  @Test("Timeout waits for cleanup before the port can be rebound")
  func timeoutCleanup() async throws {
    let port = try await availableTestPort()
    let server = try ChatGPTLocalhostCallbackServer(port: port)
    try await server.start()
    await #expect(throws: ChatGPTLocalhostCallbackError.authorizationTimedOut) {
      _ = try await server.waitForCallback(until: Date().addingTimeInterval(0.01))
    }

    let rebound = try ChatGPTLocalhostCallbackServer(port: port)
    try await rebound.start()
    try await rebound.cancel()
  }

  @Test("A typed address-in-use construction failure selects only the fallback port")
  func addressInUseFallback() async throws {
    let occupier = try await occupyIfAvailable(port: 1_455)
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    #expect(server.port == 1_457)
    try await server.cancel()
    try await occupier?.cancel()
  }

  @Test("Both registered ports produce an explicit occupied error")
  func bothPortsOccupied() async throws {
    let first = try await occupyIfAvailable(port: 1_455)
    let second = try await occupyIfAvailable(port: 1_457)
    await #expect(throws: ChatGPTLocalhostCallbackError.callbackPortsOccupied) {
      _ = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    }
    try await second?.cancel()
    try await first?.cancel()
  }

  @Test("A non-EADDRINUSE construction error never scans the fallback")
  func nonAddressInUseDoesNotFallback() async throws {
    var attemptedPorts: [UInt16] = []
    await #expect(throws: ChatGPTLocalhostCallbackError.invalidRequest) {
      _ = try await ChatGPTLocalhostCallbackServer.bindAndStart { port in
        attemptedPorts.append(port)
        throw ChatGPTLocalhostCallbackError.invalidRequest
      }
    }
    #expect(attemptedPorts == [1_455])
  }
}

private func availableTestPort() async throws -> UInt16 {
  let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
  let port = server.port
  try await server.cancel()
  return port
}

private func occupyIfAvailable(port: UInt16) async throws -> ChatGPTLocalhostCallbackServer? {
  let occupier: ChatGPTLocalhostCallbackServer
  do { occupier = try ChatGPTLocalhostCallbackServer(port: port) }
  catch {
    guard ChatGPTLocalhostCallbackServer.isAddressInUse(error) else { throw error }
    return nil
  }
  do {
    try await occupier.start()
    return occupier
  } catch {
    let startupFailure = error
    // An acquired listener must be joined even when the test is observing a bind failure.
    try await occupier.cancel()
    guard ChatGPTLocalhostCallbackServer.isAddressInUse(startupFailure) else { throw startupFailure }
    return nil
  }
}


extension CallbackNativeTests {
  @Test("Admission overflow fails explicitly and drains every accepted connection")
  func connectionAdmissionLimitFailsClosed() async throws {
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    var sockets: [Int32] = []
    defer { sockets.forEach { _ = Darwin.close($0) } }
    for _ in 0..<ChatGPTCallbackPolicy.maximumConcurrentRequests {
      sockets.append(try connectCallbackSocket(port: server.port))
    }
    try await waitForAcceptedConnections(ChatGPTCallbackPolicy.maximumConcurrentRequests, server: server)
    sockets.append(try connectCallbackSocket(port: server.port))
    await #expect(throws: ChatGPTLocalhostCallbackError.invalidRequest) {
      _ = try await server.waitForCallback(until: Date().addingTimeInterval(5))
    }
    #expect(await server.activeConnectionCount() == 0)
    try await server.cancel()
  }

  @Test("Cancel joins a stalled accepted request, not just the listening socket")
  func cancellationDrainsAcceptedConnection() async throws {
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    let socket = try connectCallbackSocket(port: server.port)
    defer { Darwin.close(socket) }
    try sendCallbackBytes("GET /auth/callback", socket: socket)
    try await waitForAcceptedConnections(1, server: server)
    try await server.cancel()
    #expect(await server.activeConnectionCount() == 0)
    let rebound = try ChatGPTLocalhostCallbackServer(port: server.port)
    try await rebound.start()
    try await rebound.cancel()
  }

  @Test("Timeout drains multiple accepted connections")
  func timeoutDrainsAcceptedConnections() async throws {
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    let first = try connectCallbackSocket(port: server.port)
    defer { Darwin.close(first) }
    let second = try connectCallbackSocket(port: server.port)
    defer { Darwin.close(second) }
    try await waitForAcceptedConnections(2, server: server)
    await #expect(throws: ChatGPTLocalhostCallbackError.authorizationTimedOut) {
      _ = try await server.waitForCallback(until: Date().addingTimeInterval(0.05))
    }
    #expect(await server.activeConnectionCount() == 0)
    try await server.cancel()
  }

  @Test("Success also drains an unrelated stalled connection")
  func successfulCallbackDrainsOtherConnections() async throws {
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    let socket = try connectCallbackSocket(port: server.port)
    defer { Darwin.close(socket) }
    try await waitForAcceptedConnections(1, server: server)
    let callback = server.redirectURI.appending(queryItems: [URLQueryItem(name: "code", value: "fixture")])
    let waiting = Task { try await server.waitForCallback(until: Date().addingTimeInterval(5)) }
    var request = URLRequest(url: callback)
    request.timeoutInterval = 3
    let (_, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(try await waiting.value == callback)
    #expect(await server.activeConnectionCount() == 0)
    try await server.cancel()
  }

  @Test("Complete invalid headers are rejected without waiting for OAuth expiration")
  func malformedHeaderDoesNotHang() async throws {
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    let socket = try connectCallbackSocket(port: server.port)
    defer { Darwin.close(socket) }
    try sendCallbackBytes(
      "GET /auth/callback HTTP/1.1\r\nHost: localhost:\(server.port)\r\nContent-Length: 8\r\n\r\n", socket: socket)
    await #expect(throws: ChatGPTLocalhostCallbackError.invalidRequest) {
      _ = try await server.waitForCallback(until: Date().addingTimeInterval(5))
    }
    #expect(await server.activeConnectionCount() == 0)
    try await server.cancel()
  }

  @Test("A cancelled caller cannot turn a cached callback into success")
  func cancellationRejectsCachedCallback() async throws {
    let server = try await ChatGPTLocalhostCallbackServer.bindAndStart()
    var request = URLRequest(url: server.redirectURI)
    request.timeoutInterval = 3
    let (_, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let gate = Signal()
    let waiting = Task {
      await gate.wait()
      return try await server.waitForCallback(until: Date().addingTimeInterval(5))
    }
    waiting.cancel()
    await gate.open()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(await server.activeConnectionCount() == 0)
    try await server.cancel()
  }
}

private func waitForAcceptedConnections(_ count: Int, server: ChatGPTLocalhostCallbackServer) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while await server.activeConnectionCount() != count {
    guard ContinuousClock.now < deadline else { throw ChatGPTLocalhostCallbackError.authorizationTimedOut }
    try await Task.sleep(for: .milliseconds(5))
  }
}

private func connectCallbackSocket(port: UInt16) throws -> Int32 {
  let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
  guard socket >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  var noSignal: Int32 = 1
  guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
    let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    Darwin.close(socket)
    throw error
  }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = port.bigEndian
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard result == 0 else {
    let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    Darwin.close(socket)
    throw error
  }
  return socket
}

private func sendCallbackBytes(_ value: String, socket: Int32) throws {
  let bytes = Array(value.utf8)
  let sent = bytes.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
  guard sent == bytes.count else { throw POSIXError(.EIO) }
}
#endif
