import ASK
import Foundation
import MCP

/// Typed tools exposed over stateless MCP: one tool per canonical
/// `ASKCommand`/`ASKQuery` case. No
/// generic execute surface exists; input schema, allowed effect, and failure
/// site stay separated per contract case.
public struct ASKMCPToolCatalog: Sendable {
    public let tools: [MCPTool]
    private let toolsByName: [String: MCPTool]

    public init() throws {
        tools = try Self.makeTools()
        toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    /// Policy-filtered catalog: gated tools are absent from `tools`, so they
    /// never reach `tools/list` or the resolver.
    public init(policy: ASKMCPPolicy) throws {
        var all = try Self.makeTools()
        all.removeAll { !policy.allowedToolNames.contains($0.name) }
        tools = all
        toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    public func tool(named name: String) -> MCPTool? {
        toolsByName[name]
    }

    public var commandToolNames: [String] {
        tools.map(\.name).filter(Self.commandNames.contains)
    }

    public var queryToolNames: [String] {
        tools.map(\.name).filter(Self.queryNames.contains)
    }

    public static let commandNames: Set<String> = [
        "quick_start", "index_workspace", "import_workspace", "stage_report", "close_day",
        "import_capture", "decide_patch", "repair_presentation", "rebuild_knowledge",
        "record_decision_memory", "record_decision_memories", "transition_decision_memory",
        "consolidate_decision_memory",
    ]

    public static let queryNames: Set<String> = [
        "search_evidence", "search_knowledge", "retrieve_evidence", "projection", "markdown_page",
        "reading_context", "storage_health", "pending_work", "source_inspect",
        "pending_patch", "decision_memory",
    ]

    private static func makeTools() throws -> [MCPTool] {
        try commandTools() + queryTools()
    }

    // MARK: - Commands (effecting)

    private static func commandTool(
        name: String,
        summary: String,
        replayPolicy: String,
        properties: [String: MCPJSONValue],
        required: [String]
    ) throws -> MCPTool {
        var envelope = properties
        envelope["dryRunOnly"] = .object([
            "type": .string("boolean"),
            "description": .string(
                "When true the call stops after plan integrity verification and applies no effect."
            ),
        ])
        return try MCPTool(
            name: name,
            description: "\(summary) Effecting command; replay policy \(replayPolicy).",
            inputSchema: ASKMCPSchema.toolInputSchema(properties: envelope, required: required),
            outputSchema: ASKMCPSchema.commandOutputSchema
        )
    }

    private static func commandTools() throws -> [MCPTool] {
        [
            try commandTool(
                name: "quick_start",
                summary: "Create a managed sample workspace with one explicitly approved report.",
                replayPolicy: "requires_resolution",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "requestedAt": ASKMCPSchema.stringType,
                    "decidedBy": ASKMCPSchema.stringType,
                    "reason": ASKMCPSchema.stringType,
                    "resetExistingWorkspace": ASKMCPSchema.booleanType,
                ],
                required: ["requestedAt"]
            ),
            try commandTool(
                name: "index_workspace",
                summary: "Index a local markdown/PDF source root without staging or committing canonical knowledge.",
                replayPolicy: "replay_safe",
                properties: [
                    "sourceRootURL": ASKMCPSchema.string(description: "Local file URL of the source root to index."),
                    "workspace": ASKMCPSchema.workspaceSelection,
                ],
                required: ["sourceRootURL"]
            ),
            try commandTool(
                name: "import_workspace",
                summary: "Index a local markdown/PDF source root and commit an explicitly approved report.",
                replayPolicy: "requires_resolution",
                properties: [
                    "sourceRootURL": ASKMCPSchema.string(description: "Local file URL of the source root to index."),
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "title": ASKMCPSchema.stringType,
                    "queryText": ASKMCPSchema.stringType,
                    "requestedAt": ASKMCPSchema.stringType,
                    "decidedBy": ASKMCPSchema.stringType,
                    "reason": ASKMCPSchema.stringType,
                    "slug": ASKMCPSchema.stringType,
                    "subjectID": ASKMCPSchema.stringType,
                    "maxEvidenceBytes": ASKMCPSchema.integerType,
                    "includeStaleEvidence": ASKMCPSchema.booleanType,
                    "resetExistingWorkspace": ASKMCPSchema.booleanType,
                ],
                required: ["sourceRootURL", "title", "queryText", "requestedAt"]
            ),
            try commandTool(
                name: "stage_report",
                summary: "Stage an evidence-backed report patch for later approval.",
                replayPolicy: "requires_resolution",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "title": ASKMCPSchema.stringType,
                    "queryText": ASKMCPSchema.stringType,
                    "requestedAt": ASKMCPSchema.stringType,
                    "slug": ASKMCPSchema.stringType,
                    "subjectID": ASKMCPSchema.stringType,
                    "maxEvidenceBytes": ASKMCPSchema.integerType,
                    "includeStaleEvidence": ASKMCPSchema.booleanType,
                ],
                required: ["title", "queryText", "requestedAt"]
            ),
            try commandTool(
                name: "close_day",
                summary: "Stage a close-day report summarizing open work and blockers.",
                replayPolicy: "requires_resolution",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "date": ASKMCPSchema.stringType,
                    "queryText": ASKMCPSchema.stringType,
                    "requestedAt": ASKMCPSchema.stringType,
                    "slug": ASKMCPSchema.stringType,
                    "subjectID": ASKMCPSchema.stringType,
                    "maxEvidenceBytes": ASKMCPSchema.integerType,
                    "includeStaleEvidence": ASKMCPSchema.booleanType,
                ],
                required: ["date", "requestedAt"]
            ),
            try commandTool(
                name: "import_capture",
                summary: "Import a captured-source manifest into the workspace.",
                replayPolicy: "requires_resolution",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "captureManifestURL": ASKMCPSchema.string(description: "Local file URL of the capture manifest."),
                    "domain": ASKMCPSchema.stringType,
                    "requestedAt": ASKMCPSchema.stringType,
                    "focusPrompt": ASKMCPSchema.stringType,
                ],
                required: ["captureManifestURL", "domain", "requestedAt"]
            ),
            try commandTool(
                name: "decide_patch",
                summary: "Approve or reject one staged patch through the review gate.",
                replayPolicy: "requires_resolution",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "patchID": ASKMCPSchema.stringType,
                    "decision": ASKMCPSchema.stringEnum(
                        ["approved", "rejected"],
                        description: "Review decision for the staged patch."
                    ),
                    "decidedBy": ASKMCPSchema.stringType,
                    "decidedAt": ASKMCPSchema.stringType,
                    "reason": ASKMCPSchema.stringType,
                    "requireFreshEvidence": ASKMCPSchema.booleanType,
                ],
                required: ["patchID", "decision", "decidedAt", "reason"]
            ),
            try commandTool(
                name: "repair_presentation",
                summary: "Idempotently rematerialize derived presentation for a durable repair token.",
                replayPolicy: "replay_safe",
                properties: [
                    "token": ASKMCPSchema.repairToken,
                    "requestedAt": ASKMCPSchema.stringType,
                ],
                required: ["token", "requestedAt"]
            ),
            try commandTool(
                name: "rebuild_knowledge",
                summary: "Rebuild derived knowledge artifacts from the canonical journal after a partial effect.",
                replayPolicy: "replay_safe",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "requestedAt": ASKMCPSchema.stringType,
                ],
                required: ["requestedAt"]
            ),
            try commandTool(
                name: "record_decision_memory",
                summary: "Record one observed or proposed decision-memory fact.",
                replayPolicy: "requires_resolution",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "record": ASKMCPSchema.openObject(
                        description: "KnowledgeCore MemoryRecord JSON; validated by core before commit."
                    ),
                ],
                required: ["record"]
            ),
            try commandTool(
                name: "record_decision_memories",
                summary: "Append many immutable STIM decision-memory records in one journal pass.",
                replayPolicy: "requires_resolution",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "records": .object([
                        "type": .string("array"),
                        "description": .string(
                            "KnowledgeCore MemoryRecord JSON objects; validated by core before commit."
                        ),
                        "items": ASKMCPSchema.openObject(
                            description: "KnowledgeCore MemoryRecord JSON object."
                        ),
                    ]),
                ],
                required: ["records"]
            ),
            try commandTool(
                name: "transition_decision_memory",
                summary: "Append one immutable decision-memory transition (verify/promote/supersede/retract/expire).",
                replayPolicy: "requires_resolution",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "transition": ASKMCPSchema.openObject(
                        description: "KnowledgeCore MemoryTransition JSON; validated by core before commit."
                    ),
                ],
                required: ["transition"]
            ),
            try commandTool(
                name: "consolidate_decision_memory",
                summary: "Rebuild generated decision-memory Markdown from canonical JSON facts.",
                replayPolicy: "requires_resolution",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "asOf": ASKMCPSchema.stringType,
                ],
                required: ["asOf"]
            ),
        ]
    }

    // MARK: - Queries (read-only)

    private static func queryTool(
        name: String,
        summary: String,
        properties: [String: MCPJSONValue],
        required: [String] = []
    ) throws -> MCPTool {
        try MCPTool(
            name: name,
            description: "\(summary) Read-only query; replay safe.",
            inputSchema: ASKMCPSchema.toolInputSchema(properties: properties, required: required),
            outputSchema: ASKMCPSchema.queryOutputSchema(for: name)
        )
    }

    private static func queryTools() throws -> [MCPTool] {
        [
            try queryTool(
                name: "search_evidence",
                summary: "Search indexed source evidence by text.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "text": ASKMCPSchema.stringType,
                    "limit": ASKMCPSchema.integerType,
                ],
                required: ["text"]
            ),
            try queryTool(
                name: "search_knowledge",
                summary: "Search committed knowledge projections by text.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "text": ASKMCPSchema.stringType,
                    "limit": ASKMCPSchema.integerType,
                ],
                required: ["text"]
            ),
            try queryTool(
                name: "retrieve_evidence",
                summary: "Retrieve bounded addressable source evidence with deterministic vectorless tree navigation.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "question": ASKMCPSchema.stringType,
                    "sourceIDs": ASKMCPSchema.stringArray(),
                    "maxSources": ASKMCPSchema.integerType,
                    "maxTreeDepth": ASKMCPSchema.integerType,
                    "maxVisitedNodes": ASKMCPSchema.integerType,
                    "maxRawEvidenceTokens": ASKMCPSchema.integerType,
                ],
                required: ["question"]
            ),
            try queryTool(
                name: "projection",
                summary: "Read one committed projection document body.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "slug": ASKMCPSchema.stringType,
                ],
                required: ["slug"]
            ),
            try queryTool(
                name: "markdown_page",
                summary: "Compile markdown text and report its page structure without touching storage.",
                properties: [
                    "markdown": ASKMCPSchema.stringType,
                    "title": ASKMCPSchema.stringType,
                    "documentID": ASKMCPSchema.stringType,
                    "sourceID": ASKMCPSchema.stringType,
                ],
                required: ["markdown"]
            ),
            try queryTool(
                name: "reading_context",
                summary: "Load reading context counts for one projection.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "projectionSlug": ASKMCPSchema.stringType,
                ],
                required: ["projectionSlug"]
            ),
            try queryTool(
                name: "storage_health",
                summary: "Report vault and evidence index health components.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection
                ]
            ),
            try queryTool(
                name: "pending_work",
                summary: "List pending patches and durable presentation repair tokens.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection
                ]
            ),
            try queryTool(
                name: "source_inspect",
                summary: "Read an indexed source range by stable ID, optionally at an exact historical checksum.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "sourceID": ASKMCPSchema.stringType,
                    "sourceVersionChecksum": ASKMCPSchema.stringType,
                    "start": ASKMCPSchema.integerType,
                    "end": ASKMCPSchema.integerType,
                ],
                required: ["sourceID"]
            ),
            try queryTool(
                name: "pending_patch",
                summary: "Read the complete patch plan and current pending status before deciding it.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "patchID": ASKMCPSchema.stringType,
                ],
                required: ["patchID"]
            ),
            try queryTool(
                name: "decision_memory",
                summary: "Build deterministic decision-memory context for a caller-supplied task frame.",
                properties: [
                    "workspace": ASKMCPSchema.workspaceSelection,
                    "frame": ASKMCPSchema.openObject(
                        description: "KnowledgeCore TaskFrame JSON defining the context scope."
                    ),
                    "budget": ASKMCPSchema.openObject(
                        description: "Optional KnowledgeCore ContextBudget JSON."
                    ),
                ],
                required: ["frame"]
            ),
        ]
    }
}
