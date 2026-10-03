import NativeAgentDomain
import Foundation

public struct WebLimits: Sendable, Equatable {
    public static let standard = WebLimits(
        maximumSearchResults: 10,
        maximumQueryBytes: 1_024,
        maximumResponseBytes: 1_048_576,
        validated: ()
    )

    public let maximumSearchResults: Int
    public let maximumQueryBytes: Int
    public let maximumResponseBytes: Int

    public init(
        maximumSearchResults: Int = 10,
        maximumQueryBytes: Int = 1_024,
        maximumResponseBytes: Int = 1_048_576
    ) throws {
        guard 1...20 ~= maximumSearchResults else {
            throw AgentError.invalidConfiguration("Web search result limit must be between 1 and 20.")
        }
        guard 1...4_096 ~= maximumQueryBytes else {
            throw AgentError.invalidConfiguration("Web search query byte limit must be between 1 and 4096.")
        }
        guard 1...8_388_608 ~= maximumResponseBytes else {
            throw AgentError.invalidConfiguration("Web response byte limit must be between 1 and 8388608.")
        }
        self.maximumSearchResults = maximumSearchResults
        self.maximumQueryBytes = maximumQueryBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    private init(
        maximumSearchResults: Int,
        maximumQueryBytes: Int,
        maximumResponseBytes: Int,
        validated: Void
    ) {
        self.maximumSearchResults = maximumSearchResults
        self.maximumQueryBytes = maximumQueryBytes
        self.maximumResponseBytes = maximumResponseBytes
    }
}

public struct WebSearchResult: Codable, Sendable, Equatable {
    public let title: String
    public let url: URL
    public let snippet: String

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public struct WebSearchPage: Sendable, Equatable {
    public let results: [WebSearchResult]
    public let nextCursor: String?

    public init(results: [WebSearchResult], nextCursor: String? = nil) {
        self.results = results
        self.nextCursor = nextCursor
    }
}

public struct WebFetchResponse: Codable, Sendable, Equatable {
    public let finalURL: URL
    public let statusCode: Int
    public let contentType: String?
    public let content: String

    public init(
        finalURL: URL,
        statusCode: Int,
        contentType: String? = nil,
        content: String
    ) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.contentType = contentType
        self.content = content
    }
}

/// Host-owned search provider. Credentials, retry, ranking, and transport stay
/// outside NativeAgent.
public protocol WebSearchService: Sendable {
    /// The provider owns cursor encoding and must reject a cursor that does not
    /// belong to the supplied query. `maximumResults` bounds one page only.
    func search(
        query: String,
        maximumResults: Int,
        cursor: String?
    ) async throws -> WebSearchPage
}

/// Host-owned HTTP reader. The service must enforce its network policy while
/// the tool pack independently verifies scheme and output bounds.
public protocol WebFetchService: Sendable {
    func fetch(url: URL, maximumResponseBytes: Int) async throws -> WebFetchResponse
}

public struct WebToolPack: ToolPack {
    public let packID = "native-agent.web"
    private let searchService: any WebSearchService
    private let fetchService: any WebFetchService
    private let limits: WebLimits

    public init(
        searchService: any WebSearchService,
        fetchService: any WebFetchService,
        limits: WebLimits = .standard
    ) {
        self.searchService = searchService
        self.fetchService = fetchService
        self.limits = limits
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: searchDefinition) { call, _ in
                let query = try normalizedQuery(call.arguments)
                guard query.utf8.count <= limits.maximumQueryBytes else {
                    throw AgentError.budgetExceeded("web.search query exceeds the configured byte limit.")
                }
                let requestedLimit: Int
                if let rawLimit = call.arguments.objectValue?["limit"] {
                    guard let parsed = rawLimit.intValue else {
                        throw AgentError.invalidToolCall("web.search limit must be an integer.")
                    }
                    requestedLimit = parsed
                } else {
                    requestedLimit = limits.maximumSearchResults
                }
                guard 1...limits.maximumSearchResults ~= requestedLimit else {
                    throw AgentError.invalidToolCall(
                        "web.search limit must be between 1 and \(limits.maximumSearchResults)."
                    )
                }
                let cursor = try searchCursor(call.arguments)
                let page = try await searchService.search(
                    query: query,
                    maximumResults: requestedLimit,
                    cursor: cursor
                )
                guard page.results.count <= requestedLimit else {
                    throw AgentError.invariantViolation(
                        "Web search provider returned more results than requested."
                    )
                }
                if let nextCursor = page.nextCursor {
                    guard nextCursor.isEmpty == false,
                          nextCursor.utf8.count <= WebCursorPolicy.maximumBytes else {
                        throw AgentError.invariantViolation("Web search provider returned an invalid cursor.")
                    }
                }
                try page.results.forEach { try validateHTTPSURL($0.url, field: "search result URL") }
                let output = JSONValue.object([
                    "results": try JSONValue.encode(page.results),
                    "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null,
                    "hasMore": .bool(page.nextCursor != nil),
                ])
                guard try output.canonicalUTF8ByteCount() <= limits.maximumResponseBytes else {
                    throw AgentError.invariantViolation(
                        "Web search provider returned output larger than the configured byte limit."
                    )
                }
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: output,
                    metadata: ["resultCount": .integer(Int64(page.results.count))]
                )
            },
            ClosureToolExecutor(definition: fetchDefinition) { call, _ in
                let rawURL = try call.arguments.stringField("url")
                guard let url = URL(string: rawURL) else {
                    throw AgentError.invalidToolCall("web.fetch url must be an absolute HTTPS URL.")
                }
                try validateHTTPSURL(url, field: "web.fetch url")
                let response = try await fetchService.fetch(
                    url: url,
                    maximumResponseBytes: limits.maximumResponseBytes
                )
                try validateHTTPSURL(response.finalURL, field: "web.fetch final URL")
                guard 100...599 ~= response.statusCode else {
                    throw AgentError.invariantViolation("Web fetch provider returned an invalid HTTP status code.")
                }
                let output = try JSONValue.encode(response)
                let responseBytes = try output.canonicalUTF8ByteCount()
                guard responseBytes <= limits.maximumResponseBytes else {
                    throw AgentError.invariantViolation(
                        "Web fetch provider returned a response larger than the configured byte limit."
                    )
                }
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: output,
                    isError: !(200...299).contains(response.statusCode),
                    metadata: [
                        "statusCode": .integer(Int64(response.statusCode)),
                        "responseBytes": .integer(Int64(responseBytes)),
                    ]
                )
            },
        ]
    }

    private var searchDefinition: ToolDefinition {
        ToolDefinition(
            name: "web.search",
            description: "Search the web through a host-provided provider in bounded pages. Pass nextCursor with the same query to continue.",
            capabilityID: "web",
            inputSchema: ToolSchema.object(
                properties: [
                    "query": ToolSchema.string(description: "Search query.", minLength: 1),
                    "limit": ToolSchema.integer(
                        description: "Maximum results in this page.",
                        minimum: 1,
                        maximum: limits.maximumSearchResults
                    ),
                    "cursor": ToolSchema.string(
                        description: "Opaque nextCursor from the preceding page for the same query.",
                        minLength: 1,
                        maxLength: WebCursorPolicy.maximumBytes
                    ),
                ],
                required: ["query"]
            ),
            approvalPolicy: .requireApproval,
            effect: .readOnly,
            metadata: ["networkAccess": .bool(true)]
        )
    }

    private var fetchDefinition: ToolDefinition {
        ToolDefinition(
            name: "web.fetch",
            description: "Fetch bounded text from an absolute HTTPS URL through a host-provided service.",
            capabilityID: "web",
            inputSchema: ToolSchema.object(
                properties: [
                    "url": ToolSchema.string(
                        description: "Absolute HTTPS URL.",
                        minLength: 1,
                        format: "uri"
                    ),
                ],
                required: ["url"]
            ),
            approvalPolicy: .requireApproval,
            effect: .readOnly,
            metadata: ["networkAccess": .bool(true)]
        )
    }
}

private enum WebCursorPolicy {
    static let maximumBytes = 4_096
}

private func normalizedQuery(_ arguments: JSONValue) throws -> String {
    let query = try arguments.stringField("query")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.isEmpty == false else {
        throw AgentError.invalidToolCall("web.search query must not be empty.")
    }
    return query
}

private func searchCursor(_ arguments: JSONValue) throws -> String? {
    guard let value = arguments.objectValue?["cursor"] else { return nil }
    guard let cursor = value.stringValue,
          cursor.isEmpty == false,
          cursor.utf8.count <= WebCursorPolicy.maximumBytes else {
        throw AgentError.invalidToolCall("web.search cursor is invalid.")
    }
    return cursor
}

private func validateHTTPSURL(_ url: URL, field: String) throws {
    guard url.scheme?.lowercased() == "https",
          url.host?.isEmpty == false,
          url.user == nil,
          url.password == nil else {
        throw AgentError.invalidToolCall("\(field) must be an absolute HTTPS URL without credentials.")
    }
}
