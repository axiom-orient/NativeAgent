import Foundation
import Testing
import ASKTutor
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TutorHTTPGatewayClientTests {
    @Test
    func gatewayClientEncodesTaskAndReadsResult() async throws {
        final class StubProtocol: URLProtocol {
            nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let handler = Self.handler else { return }
                do {
                    let (response, data) = try handler(request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        StubProtocol.handler = { request in
            let data = try #require(requestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["task"] as? String == "explain")
            #expect(request.timeoutInterval == 17)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(#"{"result":{"title":"T","summary":"S","sections":[],"comprehensionChecks":[],"followUpPrompts":[]}}"#.utf8)
            return (response, body)
        }

        let client = TutorHTTPGatewayClient(configuration: TutorHTTPGatewayConfiguration(
            baseURL: URL(string: "https://example.com/")!,
            session: session,
            requestTimeout: 17
        ))
        let request = TutorExplainModelRequest(
            learner: LearnerProfile(learnerID: "learner", updatedAt: "2026-04-10T00:00:00Z"),
            session: TutorSessionContext(sessionID: "s", title: "t", scope: .global, recentTranscript: []),
            grounding: TutorGrounding(question: "Q", answer: "A", citations: [], results: [], knowledgeGap: nil),
            projection: nil,
            responseStyle: .standard
        )
        let result = try await client.explain(request)
        #expect(result.title == "T")
        StubProtocol.handler = nil
    }


    @Test
    func gatewayClientThrowsModelErrorOnNon2xx() async throws {
        final class StubProtocol: URLProtocol {
            nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let handler = Self.handler else { return }
                do {
                    let (response, data) = try handler(request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"boom"#.utf8))
        }

        let client = TutorHTTPGatewayClient(configuration: TutorHTTPGatewayConfiguration(baseURL: URL(string: "https://example.com/")!, session: session))
        let request = TutorExplainModelRequest(
            learner: LearnerProfile(learnerID: "learner", updatedAt: "2026-04-10T00:00:00Z"),
            session: TutorSessionContext(sessionID: "s", title: "t", scope: .global, recentTranscript: []),
            grounding: TutorGrounding(question: "Q", answer: "A", citations: [], results: [], knowledgeGap: nil),
            projection: nil,
            responseStyle: .standard
        )
        await #expect(throws: ASKTutorError.self) {
            _ = try await client.explain(request)
        }
        StubProtocol.handler = nil
    }

    @Test
    func gatewayRejectsInsecureBaseURLByDefault() async throws {
        final class StubProtocol: URLProtocol {
            nonisolated(unsafe) static var requestCount = 0
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Self.requestCount += 1
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let client = TutorHTTPGatewayClient(configuration: TutorHTTPGatewayConfiguration(
            baseURL: URL(string: "http://example.com/")!,
            session: session
        ))

        do {
            _ = try await client.explain(makeExplainRequest())
            Issue.record("Expected insecure HTTP gateway URL to be rejected")
        } catch let error as ASKTutorError {
            #expect(String(describing: error).contains("https"))
        }
        #expect(StubProtocol.requestCount == 0)
    }

    @Test
    func gatewayRejectsOversizedResponsesBeforeDecoding() async throws {
        final class StubProtocol: URLProtocol {
            nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let handler = Self.handler else { return }
                let (response, data) = handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        StubProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(repeating: 0x41, count: 2_048)
            )
        }
        defer { StubProtocol.handler = nil }

        let client = TutorHTTPGatewayClient(configuration: TutorHTTPGatewayConfiguration(
            baseURL: URL(string: "https://example.com/")!,
            session: session,
            maxResponseBytes: 1_024
        ))

        do {
            _ = try await client.explain(makeExplainRequest())
            Issue.record("Expected oversized gateway response to be rejected")
        } catch let error as ASKTutorError {
            #expect(String(describing: error).contains("response body"))
        }
    }

}

private func makeExplainRequest() -> TutorExplainModelRequest {
    TutorExplainModelRequest(
        learner: LearnerProfile(learnerID: "learner", updatedAt: "2026-04-10T00:00:00Z"),
        session: TutorSessionContext(sessionID: "s", title: "t", scope: .global, recentTranscript: []),
        grounding: TutorGrounding(question: "Q", answer: "A", citations: [], results: [], knowledgeGap: nil),
        projection: nil,
        responseStyle: .standard
    )
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }

    let bufferSize = 1024
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        guard count >= 0 else {
            return nil
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return data
}
