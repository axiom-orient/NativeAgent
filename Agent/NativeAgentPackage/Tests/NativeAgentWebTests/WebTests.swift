import NativeAgentDomain
import Foundation
import Testing

@testable import NativeAgentWeb

private struct SearchService: WebSearchService {
    let results: [WebSearchResult]
    var nextCursor: String? = nil

    func search(
        query: String,
        maximumResults: Int,
        cursor: String?
    ) async throws -> WebSearchPage {
        WebSearchPage(results: results, nextCursor: nextCursor)
    }
}

@Test
func webSearchSurfacesContinuationCursor() async throws {
    let result = WebSearchResult(
        title: "NativeAgent",
        url: try #require(URL(string: "https://example.com")),
        snippet: "result"
    )
    let pack = WebToolPack(
        searchService: SearchService(results: [result], nextCursor: "page-2"),
        fetchService: FetchService(response: try response(content: "ok"))
    )
    let executor = try #require(pack.executors().first { $0.definition.name == "web.search" })
    let output = try await executor.execute(
        call: ToolCall(name: "web.search", arguments: ["query": "NativeAgent"]),
        context: context()
    ).output

    #expect(output.objectValue?["nextCursor"]?.stringValue == "page-2")
    #expect(output.objectValue?["hasMore"]?.boolValue == true)
}

private struct FetchService: WebFetchService {
    let response: WebFetchResponse

    func fetch(url: URL, maximumResponseBytes: Int) async throws -> WebFetchResponse {
        response
    }
}

@Test
func webToolsAreBoundedApprovalRequiredNetworkReads() throws {
    let pack = WebToolPack(
        searchService: SearchService(results: []),
        fetchService: FetchService(response: try response(content: "ok"))
    )
    let definitions = Dictionary(uniqueKeysWithValues: pack.executors().map {
        ($0.definition.name, $0.definition)
    })

    #expect(Set(definitions.keys) == ["web.search", "web.fetch"])
    #expect(definitions.values.allSatisfy { $0.approvalPolicy == .requireApproval })
    #expect(definitions.values.allSatisfy { $0.metadata["networkAccess"] == .bool(true) })
}

@Test
func webSearchRejectsProviderOverflowInsteadOfTruncating() async throws {
    let result = WebSearchResult(
        title: "NativeAgent",
        url: try #require(URL(string: "https://example.com")),
        snippet: "result"
    )
    let pack = WebToolPack(
        searchService: SearchService(results: [result, result]),
        fetchService: FetchService(response: try response(content: "ok")),
        limits: try WebLimits(maximumSearchResults: 1)
    )
    let executor = try #require(pack.executors().first { $0.definition.name == "web.search" })

    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(
                id: "search-overflow",
                name: "web.search",
                arguments: .object(["query": .string("NativeAgent"), "limit": .integer(1)])
            ),
            context: context()
        )
    }
}

@Test
func webSearchBoundsTheFinalWrappedOutput() async throws {
    let pack = WebToolPack(
        searchService: SearchService(results: []),
        fetchService: FetchService(response: try response(content: "ok")),
        limits: try WebLimits(maximumResponseBytes: 2)
    )
    let executor = try #require(pack.executors().first { $0.definition.name == "web.search" })

    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(
                id: "search-wrapper-large",
                name: "web.search",
                arguments: .object(["query": .string("NativeAgent")])
            ),
            context: context()
        )
    }
}

@Test
func webFetchRejectsUnsafeURLAndOversizedProviderOutput() async throws {
    let limits = try WebLimits(maximumResponseBytes: 4)
    let pack = WebToolPack(
        searchService: SearchService(results: []),
        fetchService: FetchService(response: try response(content: "12345")),
        limits: limits
    )
    let executor = try #require(pack.executors().first { $0.definition.name == "web.fetch" })

    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(
                id: "fetch-http",
                name: "web.fetch",
                arguments: .object(["url": .string("http://example.com")])
            ),
            context: context()
        )
    }
    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(
                id: "fetch-large",
                name: "web.fetch",
                arguments: .object(["url": .string("https://example.com")])
            ),
            context: context()
        )
    }
}

@Test
func webFetchBoundsTheEntireEncodedResponseNotOnlyContent() async throws {
    let limits = try WebLimits(maximumResponseBytes: 160)
    let oversizedMetadata = WebFetchResponse(
        finalURL: try #require(URL(string: "https://example.com/final")),
        statusCode: 200,
        contentType: String(repeating: "x", count: 200),
        content: "ok"
    )
    let pack = WebToolPack(
        searchService: SearchService(results: []),
        fetchService: FetchService(response: oversizedMetadata),
        limits: limits
    )
    let executor = try #require(pack.executors().first { $0.definition.name == "web.fetch" })

    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(
                id: "fetch-metadata-large",
                name: "web.fetch",
                arguments: .object(["url": .string("https://example.com")])
            ),
            context: context()
        )
    }
}

private func response(content: String) throws -> WebFetchResponse {
    WebFetchResponse(
        finalURL: try #require(URL(string: "https://example.com/final")),
        statusCode: 200,
        contentType: "text/plain",
        content: content
    )
}

private func context() -> ToolExecutionContext {
    let root = FileManager.default.temporaryDirectory
    return ToolExecutionContext(
        sessionID: "web-test",
        sessionDirectoryURL: root,
        sandboxRootURL: root
    )
}
