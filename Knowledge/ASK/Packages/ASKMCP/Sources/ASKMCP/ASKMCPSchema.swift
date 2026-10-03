import Foundation
import MCP

/// Strict JSON Schema builders for the canonical typed boundary.
///
/// Envelope keys mirror the `ASKCommand`/`ASKQuery` Codable key names exactly so
/// a single `JSONDecoder` owns the wire format and no second field naming
/// convention is introduced. Nested domain payloads (`record`, `transition`,
/// `frame`, `budget`) stay open objects because their invariants are owned by
/// `KnowledgeCore` validation, never duplicated here. Every envelope we do own
/// closes with `additionalProperties: false`.
enum ASKMCPSchema {
    static let stringType = string()
    static let booleanType: MCPJSONValue = .object(["type": .string("boolean")])
    static let integerType: MCPJSONValue = .object([
        "type": .string("integer"),
        "minimum": .integer(0),
    ])

    private static let openPayload: MCPJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(true),
    ])

    private static func caseVariant(_ key: String) -> MCPJSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([key: openPayload]),
            "required": .array([.string(key)]),
            "additionalProperties": .bool(false),
        ])
    }

    private static let diagnosticVariant: MCPJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "code": stringType,
            "operation": stringType,
            "message": stringType,
            "context": openObject(description: "Machine-readable error context."),
            "recovery": stringType,
        ]),
        "required": .array(["code", "operation", "message", "context", "recovery"].map { MCPJSONValue.string($0) }),
        "additionalProperties": .bool(false),
    ])

    private static let dryRunVariant: MCPJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "tool": stringType,
            "actionID": stringType,
            "summary": stringType,
        ]),
        "required": .array(["tool", "actionID", "summary"].map { MCPJSONValue.string($0) }),
        "additionalProperties": .bool(false),
    ])

    static let commandOutputSchema: [String: MCPJSONValue] = [
        "oneOf": .array([
            "sourcesIndexed", "workspaceApplied", "staged", "decided",
            "presentationRepaired", "knowledgeRebuilt", "decisionMemory",
            "committedWithRepairRequired", "committedWithRecoveryRequired",
        ].map(caseVariant) + [dryRunVariant, diagnosticVariant]),
    ]

    static func queryOutputSchema(for toolName: String) -> [String: MCPJSONValue] {
        let key: String
        switch toolName {
        case "search_evidence": key = "evidenceSearch"
        case "search_knowledge": key = "knowledgeSearch"
        case "retrieve_evidence": key = "evidenceRetrieved"
        case "projection": key = "projection"
        case "markdown_page": key = "markdownPage"
        case "reading_context": key = "readingContext"
        case "storage_health": key = "storageHealth"
        case "pending_work": key = "pendingWork"
        case "source_inspect": key = "sourceInspect"
        case "pending_patch": key = "pendingPatch"
        case "decision_memory": key = "decisionMemory"
        default: key = toolName
        }
        return ["oneOf": .array([caseVariant(key), diagnosticVariant])]
    }

    static func string(description: String? = nil) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = ["type": .string("string")]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    static func stringEnum(_ values: [String], description: String) -> MCPJSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map { MCPJSONValue.string($0) }),
            "description": .string(description),
        ])
    }

    static func stringArray() -> MCPJSONValue {
        .object(["type": .string("array"), "items": stringType])
    }

    /// Input-schema shape expected by `MCPTool.init(inputSchema:)`.
    static func toolInputSchema(
        description: String? = nil,
        properties: [String: MCPJSONValue],
        required: [String] = []
    ) -> [String: MCPJSONValue] {
        var schema: [String: MCPJSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.sorted().map { MCPJSONValue.string($0) }),
            "additionalProperties": .bool(false),
        ]
        if let description { schema["description"] = .string(description) }
        return schema
    }

    /// Object value for embedding inside another schema's `properties`.
    static func closedObject(
        description: String? = nil,
        properties: [String: MCPJSONValue],
        required: [String] = []
    ) -> MCPJSONValue {
        .object(toolInputSchema(description: description, properties: properties, required: required))
    }

    /// Open object for payloads whose validation lives in KnowledgeCore.
    static func openObject(description: String) -> MCPJSONValue {
        .object([
            "type": .string("object"),
            "description": .string(description),
            "additionalProperties": .bool(true),
        ])
    }

    static let workspaceSelection = closedObject(
        description: "Optional workspace route selection. Omitted fields resolve against the server configuration.",
        properties: [
            "workspaceURL": string(description: "Canonical local file URL of the workspace root."),
            "vaultURL": string(description: "Canonical local file URL of the canonical vault."),
            "indexURL": string(description: "Canonical local file URL of the evidence index."),
            "productWorkspaceURL": string(description: "Canonical local file URL of the product workspace."),
        ]
    )

    static let repairToken = closedObject(
        description: "Durable presentation repair token from pendingWork or committedWithRepairRequired.",
        properties: [
            "id": stringType,
            "actionID": stringType,
            "knowledgeRootURL": stringType,
            "productWorkspaceURL": stringType,
            "projectionSlugs": stringArray(),
            "createdAt": stringType,
        ],
        required: ["id", "actionID", "knowledgeRootURL", "productWorkspaceURL", "projectionSlugs", "createdAt"]
    )
}
