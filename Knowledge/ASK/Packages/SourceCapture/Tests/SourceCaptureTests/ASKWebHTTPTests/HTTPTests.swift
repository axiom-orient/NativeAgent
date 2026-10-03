import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Synchronization
@testable import SourceCapture

private struct CancellationTrackingState: Sendable {
    var started = false
    var stopped = false
}

private final class CancellationTrackingURLProtocol: URLProtocol {
    private static let state = Mutex(CancellationTrackingState())

    static func reset() {
        state.withLock { $0 = CancellationTrackingState() }
    }

    static var didStart: Bool {
        state.withLock(\.started)
    }

    static var didStop: Bool {
        state.withLock(\.stopped)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.withLock { $0.started = true }
    }

    override func stopLoading() {
        Self.state.withLock { $0.stopped = true }
    }
}

private struct StatusTrackingState: Sendable {
    var requestCount = 0
}

private final class NotFoundURLProtocol: URLProtocol {
    private static let state = Mutex(StatusTrackingState())

    static func reset() {
        state.withLock { $0 = StatusTrackingState() }
    }

    static var requestCount: Int {
        state.withLock(\.requestCount)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.withLock { $0.requestCount += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("not found".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OversizedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x78, count: 8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct HTTPTests {
    @Test
    func invalidURLIsRejected() async {
        await #expect(throws: Error.self) {
            _ = try await WebHTTPCollector.fetchURL("not a url")
        }
    }

    @Test
    func cancelingFetchURLCancelsUnderlyingTask() async throws {
        CancellationTrackingURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CancellationTrackingURLProtocol.self]
        let session = URLSession(configuration: config)

        let task = Task {
            _ = try await WebHTTPCollector.fetchURL(
                "https://example.com/",
                timeout: 1,
                maxAttempts: 1,
                session: session
            )
        }

        try await waitUntil("request start") {
            CancellationTrackingURLProtocol.didStart
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected fetchURL cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        try await waitUntil("request stop") {
            CancellationTrackingURLProtocol.didStop
        }
    }

    @Test
    func nonRetryableStatusIsAttemptedOnlyOnce() async {
        NotFoundURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotFoundURLProtocol.self]
        let session = URLSession(configuration: configuration)

        await #expect(throws: Error.self) {
            _ = try await WebHTTPCollector.fetchURL(
                "https://example.com/",
                maxAttempts: 3,
                session: session
            )
        }

        #expect(NotFoundURLProtocol.requestCount == 1)
    }

    @Test
    func responseBodyLimitIsEnforcedForUndeclaredLength() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let policy = WebFetchPolicy(maxResponseBytes: 4)

        await #expect(throws: Error.self) {
            _ = try await WebHTTPCollector.fetchURL(
                "https://example.com/",
                maxAttempts: 1,
                session: session,
                policy: policy
            )
        }
    }

    @Test
    func redirectResponseIsNotTreatedAsCapturedContent() throws {
        let url = try #require(URL(string: "https://example.com/start"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.com/next"]
        ))

        #expect(throws: Error.self) {
            _ = try decodeFetchedResponse(data: Data(), response: response, originalURL: url.absoluteString)
        }
    }

    private func waitUntil(
        _ label: String,
        attempts: Int = 40,
        sleepNanoseconds: UInt64 = 50_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        #expect(condition(), "\(label) was not observed")
    }
}
