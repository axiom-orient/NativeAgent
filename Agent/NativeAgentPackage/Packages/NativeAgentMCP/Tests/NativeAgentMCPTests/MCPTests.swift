import NativeAgentDomain
import Foundation
import MCP
import Testing

@testable import NativeAgentMCP

private actor MCPTransportStub: MCPClientTransport {
    nonisolated let endpointIdentity = "native-agent-mcp-tests"
    let pages: [String?: MCPListToolsResult]
    let callResult: MCPCallToolResult
    private var methods: [String] = []

    init(pages: [String?: MCPListToolsResult], callResult: MCPCallToolResult) {
        self.pages = pages
        self.callResult = callResult
    }

    func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
        methods.append(request.method)
        let value: [String: MCPJSONValue]
        switch request.method {
        case "tools/list":
            let cursor: String?
            if case .string(let value)? = request.params["cursor"] {
                cursor = value
            } else {
                cursor = nil
            }
            guard let page = pages[cursor], let object = page.json.objectValue else {
                throw AgentError.notFound("Missing MCP stub page.")
            }
            value = object
        case "tools/call":
            guard let object = callResult.json.objectValue else {
                throw AgentError.invariantViolation("MCP stub result must be an object.")
            }
            value = object
        default:
            throw AgentError.unsupportedSurface("Unexpected MCP method: \(request.method)")
        }

        let message = MCPWireMessage.result(MCPWireResult(id: request.id, value: value))
        let frames = AsyncThrowingStream<MCPWireMessage, any Error> { continuation in
            continuation.yield(message)
            continuation.finish()
        }
        return MCPClientExchange(frames: frames) { _ in }
    }

    func recordedMethods() -> [String] { methods }
}

@Test
func mcpDiscoveryMapsBoundedPagesAndKeepsApprovalFailClosed() async throws {
    let first = try tool(name: "read.page", readOnly: true)
    let second = try tool(name: "write", readOnly: false)
    let transport = MCPTransportStub(
        pages: [
            nil: MCPListToolsResult(tools: [first], nextCursor: "next"),
            "next": MCPListToolsResult(tools: [second]),
        ],
        callResult: try MCPCallToolResult(content: [.text(MCPTextContent(text: "done"))])
    )
    let pack = try await MCPToolPack.discover(
        serverID: "docs",
        client: try client(transport: transport)
    )
    let executors = pack.executors()

    #expect(executors.map(\.definition.name) == ["mcp.docs.read.page", "mcp.docs.write"])
    #expect(executors.allSatisfy { $0.definition.approvalPolicy == .requireApproval })
    #expect(executors[0].definition.metadata["mcpReadOnlyHint"] == .bool(true))

    let result = try await executors[0].execute(
        call: ToolCall(
            id: "mcp-call",
            name: "mcp.docs.read.page",
            arguments: .object(["query": .string("NativeAgent")])
        ),
        context: context()
    )
    #expect(!result.isError)
    #expect(await transport.recordedMethods() == ["tools/list", "tools/list", "tools/call"])
}

@Test
func mcpDiscoveryRejectsDuplicateToolsAndCursorCycles() async throws {
    let duplicate = try tool(name: "same", readOnly: true)
    let duplicateTransport = MCPTransportStub(
        pages: [nil: MCPListToolsResult(tools: [duplicate, duplicate])],
        callResult: try MCPCallToolResult()
    )
    await #expect(throws: (any Error).self) {
        _ = try await MCPToolPack.discover(
            serverID: "duplicate",
            client: try client(transport: duplicateTransport)
        )
    }

    let cycleTransport = MCPTransportStub(
        pages: [
            nil: MCPListToolsResult(tools: [], nextCursor: "again"),
            "again": MCPListToolsResult(tools: [], nextCursor: "again"),
        ],
        callResult: try MCPCallToolResult()
    )
    await #expect(throws: AgentError.self) {
        _ = try await MCPToolPack.discover(
            serverID: "cycle",
            client: try client(transport: cycleTransport)
        )
    }
}

@Test
func mcpClientEnforcesCanonicalSchemaBeforeTransportCall() async throws {
    let constrained = try tool(
        name: "search.docs",
        readOnly: true,
        querySchema: [
            "type": .string("string"),
            "pattern": .string("^[A-Z]+$")
        ]
    )
    let transport = MCPTransportStub(
        pages: [nil: MCPListToolsResult(tools: [constrained])],
        callResult: try MCPCallToolResult()
    )
    let pack = try await MCPToolPack.discover(
        serverID: "schema",
        client: try client(transport: transport)
    )
    let executor = try #require(pack.executors().first)

    await #expect(throws: (any Error).self) {
        _ = try await executor.execute(
            call: ToolCall(
                name: "mcp.schema.search.docs",
                arguments: .object(["query": .string("lowercase")])
            ),
            context: context()
        )
    }
    #expect(await transport.recordedMethods() == ["tools/list"])
}

@Test
func mcpDiscoveryRejectsSchemasUnsupportedByNativeAgentAndInvalidMappedNames() async throws {
    let unsupportedSchema = try MCPTool(
        name: "composed",
        description: "Unsupported composition.",
        inputSchema: [
            "type": .string("object"),
            "allOf": .array([.object(["type": .string("object")])]),
        ]
    )
    let schemaTransport = MCPTransportStub(
        pages: [nil: MCPListToolsResult(tools: [unsupportedSchema])],
        callResult: try MCPCallToolResult()
    )
    await #expect(throws: AgentError.self) {
        _ = try await MCPToolPack.discover(
            serverID: "schema",
            client: try client(transport: schemaTransport)
        )
    }

    let invalidName = try tool(name: "read/path", readOnly: true)
    let invalidNameTransport = MCPTransportStub(
        pages: [nil: MCPListToolsResult(tools: [invalidName])],
        callResult: try MCPCallToolResult()
    )
    await #expect(throws: AgentError.self) {
        _ = try await MCPToolPack.discover(
            serverID: "names",
            client: try client(transport: invalidNameTransport)
        )
    }

    let longName = try tool(name: String(repeating: "a", count: 120), readOnly: true)
    let longNameTransport = MCPTransportStub(
        pages: [nil: MCPListToolsResult(tools: [longName])],
        callResult: try MCPCallToolResult()
    )
    await #expect(throws: AgentError.self) {
        _ = try await MCPToolPack.discover(
            serverID: "long-server-name",
            client: try client(transport: longNameTransport)
        )
    }
}

private func client(transport: some MCPClientTransport) throws -> MCPClient {
    let configuration = try MCPClientConfiguration(
        implementation: MCPImplementation(name: "NativeAgentTests", version: "1"),
        capabilities: MCPClientCapabilities(),
        requestTimeout: nil
    )
    return try MCPClient(transport: transport, configuration: configuration)
}

private func tool(
    name: String,
    readOnly: Bool,
    querySchema: [String: MCPJSONValue] = ["type": .string("string")]
) throws -> MCPTool {
    try MCPTool(
        name: name,
        description: "Test MCP tool.",
        inputSchema: [
            "type": .string("object"),
            "properties": .object(["query": .object(querySchema)]),
            "additionalProperties": .bool(false),
        ],
        annotations: ["readOnlyHint": .bool(readOnly)]
    )
}

private func context() -> ToolExecutionContext {
    let root = FileManager.default.temporaryDirectory
    return ToolExecutionContext(
        sessionID: "mcp-test",
        sessionDirectoryURL: root,
        sandboxRootURL: root
    )
}

private actor CancellationWriteProbe: MCPClientTransport {
    nonisolated let endpointIdentity = "cancellation-write-probe"
    private(set) var completedWrite = false

    func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
        MCPClientExchange(frames: AsyncThrowingStream { $0.finish() }) { _ in
            try await self.writeCancellation()
        }
    }

    private func writeCancellation() async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(10))
        completedWrite = true
    }
}

@Test
func cancellationNotificationFinishesDespiteCancelledCaller() async throws {
    let underlying = CancellationWriteProbe()
    let transport = MCPCancellationSafeTransport(underlying)
    let exchange = try await transport.open(MCPWireRequest(id: .string("cancel"), method: "ping", params: [:]))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await exchange.cancel(reason: "test")
        #expect(await underlying.completedWrite)
    }
    try await task.value
}

@Test
func unsupportedDialectCannotDisableBridgeValidation() async throws {
    let remote = try MCPTool(name: "opaque", inputSchema: [
        "$schema": .string("https://example.invalid/custom"),
        "type": .string("object"),
        "required": .array([.string("query")]),
        "properties": .object(["query": .object(["type": .string("string"), "pattern": .string("^safe$")])])
    ])
    let transport = MCPTransportStub(pages: [nil: MCPListToolsResult(tools: [remote])], callResult: try MCPCallToolResult())
    await #expect(throws: (any Error).self) {
        _ = try await MCPToolPack.discover(serverID: "dialect", client: client(transport: transport))
    }
    await #expect(throws: (any Error).self) {
        _ = try await MCPToolPack.discover(serverID: "dialect", transport: transport,
            configuration: MCPClientConfiguration(implementation: MCPImplementation(name: "probe", version: "1"), capabilities: MCPClientCapabilities()))
    }
    #expect(!(await transport.recordedMethods()).contains("tools/call"))
}
