import NativeAgentDomain
import Foundation
import MCP

public struct MCPLimits: Sendable, Equatable {
    public static let standardMaximumPages = 8
    public static let supportedMaximumPages = 32
    public static let standardMaximumTools = ModelToolContract.maximumDefinitionCount
    public static let supportedMaximumTools = ModelToolContract.maximumDefinitionCount
    public static let standardMaximumToolSchemaBytes = 65_536
    public static let supportedMaximumToolSchemaBytes = 1_048_576
    public static let standardMaximumResultBytes = 1_048_576
    public static let supportedMaximumResultBytes = 8_388_608
    public static let maximumServerIDUTF8Bytes = 48
    public static let maximumRemoteToolNameUTF8Bytes = 128
    public static let maximumJSONDepth = 64
    public static let maximumJSONContainerElements = 16_384
    public static let maximumJSONNumberBytes = 128

    public static let standard = MCPLimits(
        maximumPages: standardMaximumPages,
        maximumTools: standardMaximumTools,
        maximumToolSchemaBytes: standardMaximumToolSchemaBytes,
        maximumResultBytes: standardMaximumResultBytes,
        validated: ()
    )

    public let maximumPages: Int
    public let maximumTools: Int
    public let maximumToolSchemaBytes: Int
    public let maximumResultBytes: Int

    public init(
        maximumPages: Int = Self.standardMaximumPages,
        maximumTools: Int = Self.standardMaximumTools,
        maximumToolSchemaBytes: Int = Self.standardMaximumToolSchemaBytes,
        maximumResultBytes: Int = Self.standardMaximumResultBytes
    ) throws {
        guard 1...Self.supportedMaximumPages ~= maximumPages else {
            throw AgentError.invalidConfiguration(
                "MCP page limit must be between 1 and \(Self.supportedMaximumPages)."
            )
        }
        guard 1...Self.supportedMaximumTools ~= maximumTools else {
            throw AgentError.invalidConfiguration(
                "MCP tool limit must be between 1 and \(Self.supportedMaximumTools)."
            )
        }
        guard 1...Self.supportedMaximumToolSchemaBytes ~= maximumToolSchemaBytes else {
            throw AgentError.invalidConfiguration(
                "MCP tool schema byte limit exceeds the supported bound."
            )
        }
        guard 1...Self.supportedMaximumResultBytes ~= maximumResultBytes else {
            throw AgentError.invalidConfiguration(
                "MCP result byte limit exceeds the supported bound."
            )
        }
        self.maximumPages = maximumPages
        self.maximumTools = maximumTools
        self.maximumToolSchemaBytes = maximumToolSchemaBytes
        self.maximumResultBytes = maximumResultBytes
    }

    private init(
        maximumPages: Int,
        maximumTools: Int,
        maximumToolSchemaBytes: Int,
        maximumResultBytes: Int,
        validated: Void
    ) {
        self.maximumPages = maximumPages
        self.maximumTools = maximumTools
        self.maximumToolSchemaBytes = maximumToolSchemaBytes
        self.maximumResultBytes = maximumResultBytes
    }
}

public struct MCPToolPack: ToolPack {
    public let packID: String
    private let tools: [MCPMappedTool]
    private let client: MCPClient
    private let limits: MCPLimits

    private init(
        serverID: String,
        tools: [MCPMappedTool],
        client: MCPClient,
        limits: MCPLimits
    ) {
        self.packID = "native-agent.mcp.\(serverID)"
        self.tools = tools
        self.client = client
        self.limits = limits
    }

    /// Discovers a bounded catalog once. The resulting immutable tool pack can
    /// be registered with Agent without hidden refresh or transport work.
    /// Preferred composition: cancellation is drained before a cancelled call
    /// returns. The host retains the underlying transport to shut it down.
    public static func discover<Transport: MCPClientTransport>(
        serverID: String,
        transport: Transport,
        configuration: MCPClientConfiguration,
        limits: MCPLimits = .standard
    ) async throws -> MCPToolPack {
        let client = try MCPClient(
            transport: MCPCancellationSafeTransport(transport), configuration: configuration)
        return try await discover(serverID: serverID, client: client, limits: limits)
    }

    public static func discover(
        serverID: String,
        client: MCPClient,
        limits: MCPLimits = .standard
    ) async throws -> MCPToolPack {
        try validateServerID(serverID)
        var cursor: String?
        var seenCursors: Set<String> = []
        var seenRemoteNames: Set<String> = []
        var mapped: [MCPMappedTool] = []

        for pageIndex in 0..<limits.maximumPages {
            let page = try await client.listTools(cursor: cursor)
            guard page.resultType == .complete else {
                throw AgentError.unsupportedSurface("MCP tools/list returned an incomplete result.")
            }
            for tool in page.tools {
                guard seenRemoteNames.insert(tool.name).inserted else {
                    throw AgentError.invalidConfiguration("MCP catalog contains duplicate tool: \(tool.name)")
                }
                guard mapped.count < limits.maximumTools else {
                    throw AgentError.budgetExceeded(
                        "MCP catalog exceeds the configured tool limit of \(limits.maximumTools)."
                    )
                }
                mapped.append(
                    try map(
                        tool: tool,
                        serverID: serverID,
                        maximumSchemaBytes: limits.maximumToolSchemaBytes
                    )
                )
            }

            guard let next = page.nextCursor else {
                return MCPToolPack(
                    serverID: serverID,
                    tools: mapped,
                    client: client,
                    limits: limits
                )
            }
            guard next.isEmpty == false, seenCursors.insert(next).inserted else {
                throw AgentError.invariantViolation("MCP tools/list returned an invalid cursor cycle.")
            }
            cursor = next
            if pageIndex + 1 == limits.maximumPages {
                throw AgentError.budgetExceeded(
                    "MCP catalog exceeds the configured page limit of \(limits.maximumPages)."
                )
            }
        }
        throw AgentError.invariantViolation("MCP catalog discovery ended without a terminal page.")
    }

    public func executors() -> [any ToolExecutor] {
        tools.map {
            MCPToolExecutor(mapped: $0, client: client, maximumResultBytes: limits.maximumResultBytes)
        }
    }
}

private struct MCPMappedTool: Sendable {
    let remoteName: String
    let validationPlan: any MCPJSONSchemaValidationPlan
    let definition: ToolDefinition
}

private struct MCPToolExecutor: ToolExecutor {
    let mapped: MCPMappedTool
    let client: MCPClient
    let maximumResultBytes: Int

    var definition: ToolDefinition { mapped.definition }

    func execute(call: ToolCall, context: ToolExecutionContext) async throws -> ToolResult {
        guard let arguments = call.arguments.objectValue else {
            throw AgentError.invalidToolCall("MCP tool arguments must be an object.")
        }
        let remoteArguments = try arguments.mapValues(mcpValue(from:))
        try mapped.validationPlan.validate(.object(remoteArguments))
        let result = try await client.callTool(
            MCPCallToolParams(
                name: mapped.remoteName,
                arguments: remoteArguments
            )
        )
        guard result.resultType == .complete else {
            throw AgentError.unsupportedSurface(
                "MCP input-required results need explicit host elicitation and are not completed by this bridge."
            )
        }
        _ = try result.json.encoded(
            limits: MCPJSONLimits(
                maximumDocumentBytes: maximumResultBytes,
                maximumDepth: MCPLimits.maximumJSONDepth,
                maximumStringBytes: maximumResultBytes,
                maximumContainerElements: MCPLimits.maximumJSONContainerElements,
                maximumNumberBytes: MCPLimits.maximumJSONNumberBytes
            )
        )
        return ToolResult(
            callID: call.id,
            toolName: call.name,
            output: try nativeAgentValue(from: result.json),
            isError: result.isError,
            metadata: ["mcpRemoteTool": .string(mapped.remoteName)]
        )
    }
}

private func validateServerID(_ value: String) throws {
    guard value.isEmpty == false,
          value.utf8.count <= MCPLimits.maximumServerIDUTF8Bytes,
          value.unicodeScalars.allSatisfy({ isSafeIdentifierComponent($0, allowPeriod: false) }) else {
        throw AgentError.invalidConfiguration(
            "MCP serverID must contain only letters, digits, hyphen, or underscore and fit in \(MCPLimits.maximumServerIDUTF8Bytes) bytes."
        )
    }
}

private func map(
    tool: MCPTool,
    serverID: String,
    maximumSchemaBytes: Int
) throws -> MCPMappedTool {
    guard tool.name.trimmingCharacters(in: .whitespacesAndNewlines) == tool.name,
          tool.name.isEmpty == false,
          tool.name.utf8.count <= MCPLimits.maximumRemoteToolNameUTF8Bytes,
          tool.name.unicodeScalars.allSatisfy({ isSafeIdentifierComponent($0, allowPeriod: true) }) else {
        throw AgentError.invalidConfiguration("MCP tool has an invalid name.")
    }
    let mappedName = "mcp.\(serverID).\(tool.name)"
    guard ModelToolContract.isValidName(mappedName) else {
        throw AgentError.budgetExceeded(
            "Mapped MCP tool name exceeds the model contract: \(tool.name)"
        )
    }
    let description = tool.descriptionText ?? "MCP tool \(tool.name) from \(serverID)."
    guard description.utf8.count <= ModelToolContract.maximumDescriptionUTF8Bytes else {
        throw AgentError.budgetExceeded(
            "MCP tool description exceeds the model contract limit of \(ModelToolContract.maximumDescriptionUTF8Bytes) bytes: \(tool.name)"
        )
    }
    _ = try tool.json.encoded(
        limits: MCPJSONLimits(
            maximumDocumentBytes: maximumSchemaBytes,
            maximumDepth: MCPLimits.maximumJSONDepth,
            maximumStringBytes: maximumSchemaBytes,
            maximumContainerElements: MCPLimits.maximumJSONContainerElements,
            maximumNumberBytes: MCPLimits.maximumJSONNumberBytes
        )
    )
    let schema = try nativeAgentValue(from: .object(tool.inputSchema))
    try rejectUnsupportedSchemaKeywords(schema, path: tool.name)
    let readOnlyHint = tool.annotations?["readOnlyHint"]?.boolValue ?? false
    return MCPMappedTool(
        remoteName: tool.name,
        validationPlan: try MCPJSONSchemaValidator().compile(.object(tool.inputSchema)),
        definition: ToolDefinition(
            name: mappedName,
            description: description,
            capabilityID: .mcp,
            inputSchema: schema,
            approvalPolicy: .requireApproval,
            metadata: [
                "mcpServerID": .string(serverID),
                "mcpRemoteTool": .string(tool.name),
                "mcpReadOnlyHint": .bool(readOnlyHint),
            ]
        )
    )
}

private func rejectUnsupportedSchemaKeywords(_ schema: JSONValue, path: String) throws {
    guard let object = schema.objectValue else { return }
    let unsupported = ["$ref", "allOf", "anyOf", "oneOf"].filter { object[$0] != nil }
    guard unsupported.isEmpty else {
        throw AgentError.unsupportedSurface(
            "MCP tool schema at \(path) uses unsupported keyword(s): \(unsupported.joined(separator: ", "))."
        )
    }
    if let properties = object["properties"]?.objectValue {
        for (name, child) in properties {
            try rejectUnsupportedSchemaKeywords(child, path: "\(path).\(name)")
        }
    }
    if let items = object["items"] {
        try rejectUnsupportedSchemaKeywords(items, path: "\(path)[]")
    }
}

private func nativeAgentValue(from value: MCPJSONValue) throws -> JSONValue {
    switch value {
    case .null:
        return .null
    case .bool(let value):
        return .bool(value)
    case .string(let value):
        return .string(value)
    case .number(let value):
        if let integer = value.int64Value {
            return .integer(integer)
        }
        if value.isInteger {
            throw AgentError.unsupportedSurface(
                "MCP integer is outside NativeAgent JSON's signed 64-bit range."
            )
        }
        guard let number = value.doubleValue else {
            throw AgentError.unsupportedSurface("MCP number cannot be represented by NativeAgent JSON.")
        }
        return .number(number)
    case .array(let values):
        return .array(try values.map(nativeAgentValue(from:)))
    case .object(let values):
        return .object(try values.mapValues(nativeAgentValue(from:)))
    }
}

private func isSafeIdentifierComponent(_ scalar: UnicodeScalar, allowPeriod: Bool) -> Bool {
    switch scalar.value {
    case 48...57, 65...90, 97...122:
        return true
    case 45, 95:
        return true
    case 46:
        return allowPeriod
    default:
        return false
    }
}

private func mcpValue(from value: JSONValue) throws -> MCPJSONValue {
    switch value {
    case .null:
        return .null
    case .bool(let value):
        return .bool(value)
    case .string(let value):
        return .string(value)
    case .integer(let value):
        return .integer(value)
    case .number(let value):
        return try .double(value)
    case .array(let values):
        return .array(try values.map(mcpValue(from:)))
    case .object(let values):
        return .object(try values.mapValues(mcpValue(from:)))
    }
}
