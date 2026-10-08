import Foundation
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct StaticRemoteSkillFetcher: RemoteSkillFetcher {
    let markdown: String
    var package: RemoteSkillPackage?
    var pluginRepository: RemoteSkillPluginRepository?

    func fetchSkillMarkdown(baseURL: URL) async throws -> String {
        markdown
    }

    func fetchSkillPackage(baseURL: URL) async throws -> RemoteSkillPackage {
        if let package {
            return package
        }
        return RemoteSkillPackage(files: [
            RemoteSkillPackageFile(relativePath: "SKILL.md", data: Data(markdown.utf8))
        ])
    }

    func fetchSkillPluginRepository(repositoryURL: URL) async throws -> RemoteSkillPluginRepository
    {
        guard let pluginRepository else {
            throw AgentError.notFound("No static remote plugin repository configured")
        }
        return pluginRepository
    }
}

final class StaticHTTPURLProtocol: URLProtocol {
    private static let state = StaticHTTPURLProtocolState()

    static func configure(responses newResponses: [String: (status: Int, data: Data)]) {
        state.configure(responses: newResponses)
    }

    static func requestedURLs() -> [String] {
        state.requestedURLs()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: AgentError.invalidToolCall("Missing request URL"))
            return
        }
        let key = url.absoluteString
        let response = Self.state.response(for: key)
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// Every access to storage is protected by the lock, including URLProtocol callbacks.
final class StaticHTTPURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = StaticHTTPURLProtocolStorage()

    func configure(responses newResponses: [String: (status: Int, data: Data)]) {
        lock.withLock {
            storage.responses.merge(newResponses) { _, new in new }
        }
    }

    func requestedURLs() -> [String] {
        lock.withLock { storage.requested }
    }

    func response(for url: String) -> (status: Int, data: Data) {
        lock.withLock {
            storage.requested.append(url)
            return storage.responses[url] ?? (404, Data())
        }
    }
}

struct StaticHTTPURLProtocolStorage: Sendable {
    var responses: [String: (status: Int, data: Data)] = [:]
    var requested: [String] = []
}
