import ASK
import Foundation
import MCP

/// Routes one stateless `tools/call` to the canonical ASK typed boundary.
///
/// Every call rebuilds a deterministic plan from its own arguments and passes
/// through plan → dry-run → apply (or straight to query). The MCP protocol layer
/// retains no request session or request-local cache between calls. Durable ASK
/// workspace state is intentionally persistent and is visible to later calls;
/// mutation ordering remains owned by the application mutation lane inside root ASK.
public struct ASKMCPRequestDispatcher: Sendable {
    private let client: ASKClient
    private let configuration: ASKConfiguration
    private let catalog: ASKMCPToolCatalog
    private let policyConfiguration: ASKMCPPolicyConfiguration

    public init(configuration: ASKConfiguration) throws {
        try self.init(
            configuration: configuration,
            catalog: ASKMCPToolCatalog(),
            policyConfiguration: ASKMCPPolicyConfiguration(policy: .readOnly)
        )
    }

    public init(configuration: ASKConfiguration, catalog: ASKMCPToolCatalog) throws {
        try self.init(
            configuration: configuration,
            catalog: catalog,
            policyConfiguration: ASKMCPPolicyConfiguration(policy: .readOnly)
        )
    }

    public init(
        configuration: ASKConfiguration,
        catalog: ASKMCPToolCatalog,
        policyConfiguration: ASKMCPPolicyConfiguration
    ) throws {
        self.client = ASKClient(configuration: configuration)
        self.configuration = configuration
        self.catalog = catalog
        self.policyConfiguration = policyConfiguration
    }

    /// True when the policy allows this tool at all. Disallowed tools are
    /// rejected as unknown so their existence stays hidden; this mirrors the
    /// not-advertised barrier already applied by the tool resolver.
    static func isAllowed(_ name: String, under policy: ASKMCPPolicy) -> Bool {
        policy.allowedToolNames.contains(name)
    }

    func callTool(name: String, arguments: [String: MCPJSONValue]) async throws -> MCPCallToolResult {
        guard catalog.tool(named: name) != nil else {
            throw MCPRPCError(
                code: -32602,
                message: "Unknown tool",
                data: .object(["name": .string(name)])
            )
        }
        guard Self.isAllowed(name, under: policyConfiguration.policy) else {
            // Disallowed tools are rejected as unknown so their existence
            // stays hidden; this mirrors the not-advertised barrier already
            // applied by the tool resolver.
            throw MCPRPCError(
                code: -32602,
                message: "Unknown tool",
                data: .object(["name": .string(name)])
            )
        }
        if ASKMCPToolCatalog.commandNames.contains(name) {
            return try await runCommand(named: name, arguments: arguments)
        }
        return try await runQuery(named: name, arguments: arguments)
    }

    /// Synthesized Codable requires every non-optional key even when the typed
    /// initializer provides a default, so arguments omitted at the boundary are
    /// materialized here from the canonical defaults declared by each ASK
    /// contract initializer. An empty workspace selection resolves routes
    /// against server configuration.
    static let omittedArgumentDefaults: [String: [String: MCPJSONValue]] = [
        "quick_start": [
            "decidedBy": .string("ask"),
            "reason": .string("ASK quick-start approval"),
            "resetExistingWorkspace": .bool(false),
        ],
        "import_workspace": [
            "decidedBy": .string("ask"),
            "reason": .string("ASK workspace import approval"),
            "maxEvidenceBytes": .integer(262_144),
            "includeStaleEvidence": .bool(false),
            "resetExistingWorkspace": .bool(false),
        ],
        "stage_report": [
            "maxEvidenceBytes": .integer(262_144),
            "includeStaleEvidence": .bool(false),
        ],
        "close_day": [
            "maxEvidenceBytes": .integer(262_144),
            "includeStaleEvidence": .bool(false),
        ],
        "decide_patch": [
            "decidedBy": .string("ask"),
            "requireFreshEvidence": .bool(true),
        ],
        "decision_memory": [
            "budget": .object([
                "blockingLTSMTokens": .integer(300),
                "ltsmTokens": .integer(300),
                "mtemTokens": .integer(500),
                "stimTokens": .integer(300),
                "uncertaintyTokens": .integer(100),
                "totalTokens": .integer(1_200),
            ]),
        ],
        "search_evidence": ["limit": .integer(100)],
        "search_knowledge": ["limit": .integer(100)],
        "retrieve_evidence": [
            "sourceIDs": .array([]),
            "maxSources": .integer(64),
            "maxTreeDepth": .integer(8),
            "maxVisitedNodes": .integer(128),
            "maxRawEvidenceTokens": .integer(32_768),
        ],
        "markdown_page": [
            "documentID": .string("ask-markdown"),
            "sourceID": .string("ask-source"),
        ],
    ]

    static func normalizedEnvelope(
        forTool name: String,
        arguments: [String: MCPJSONValue]
    ) -> [String: MCPJSONValue] {
        var envelope = arguments
        let ownsWorkspaceRoute = name != "markdown_page" && name != "repair_presentation"
        if ownsWorkspaceRoute, envelope["workspace"] == nil {
            envelope["workspace"] = .object([:])
        }
        if let defaults = omittedArgumentDefaults[name] {
            for (key, value) in defaults where envelope[key] == nil {
                envelope[key] = value
            }
        }
        return envelope
    }

    // MARK: - Commands


    /// Canonical patch commits are enabled only by the externally selected
    /// `full` policy. The operator identity is injected out-of-band; no model
    /// supplied boolean is treated as an authorization boundary.
    static func approvalGate(
        forTool name: String,
        dryRunOnly: Bool,
        envelope: [String: MCPJSONValue],
        policyConfiguration: ASKMCPPolicyConfiguration
    ) -> Result<[String: MCPJSONValue], ASKDiagnostic> {
        guard ASKToolSurface.bundledCommitTools.contains(name), !dryRunOnly else {
            return .success(envelope)
        }
        guard policyConfiguration.policy == .full else {
            return .failure(ASKDiagnostic(
                code: .unsupported,
                operation: .apply,
                message: "Approvals are disabled under the current write policy.",
                context: ["tool": name],
                recovery: .correctInput
            ))
        }
        guard let identity = policyConfiguration.resolvedOperatorIdentity else {
            return .failure(ASKDiagnostic(
                code: .invalidRequest,
                operation: .apply,
                message: "\(name) requires ASK_OPERATOR identity in full policy mode.",
                context: ["tool": name],
                recovery: .correctInput
            ))
        }
        var gated = envelope
        gated["decidedBy"] = .string(identity)
        return .success(gated)
    }

    private struct DryRunPayload: Encodable {
        let tool: String
        let actionID: String
        let summary: String
    }

    private func runCommand(
        named name: String,
        arguments: [String: MCPJSONValue]
    ) async throws -> MCPCallToolResult {
        var envelope = arguments
        let dryRunOnly = envelope.removeValue(forKey: "dryRunOnly")?.boolValue ?? false
        envelope = Self.normalizedEnvelope(forTool: name, arguments: envelope)
        if let diagnostic = resourceAuthorizationDiagnostic(forTool: name, envelope: envelope, operation: .apply) {
            return try failure(diagnostic)
        }

        switch Self.approvalGate(
            forTool: name,
            dryRunOnly: dryRunOnly,
            envelope: envelope,
            policyConfiguration: policyConfiguration
        ) {
        case .success(let gated):
            envelope = gated
        case .failure(let diagnostic):
            return try failure(diagnostic)
        }

        let command: ASKCommand?
        do {
            command = try makeCommand(named: name, envelope: envelope)
        } catch {
            return try failure(decodingDiagnostic(forTool: name, operation: .apply))
        }
        guard let command else {
            throw MCPRPCError(
                code: -32602,
                message: "Unknown tool",
                data: .object(["name": .string(name)])
            )
        }
        do {
            let plan = try client.plan(command)
            if dryRunOnly {
                _ = try client.dryRun(plan)
                return try result(DryRunPayload(tool: name, actionID: plan.actionID, summary: plan.summary))
            }
            let outcome = try await client.apply(plan)
            return try result(outcome)
        } catch let diagnostic as ASKDiagnostic {
            return try failure(diagnostic)
        }
    }

    private func makeCommand(
        named name: String,
        envelope: [String: MCPJSONValue]
    ) throws -> ASKCommand? {
        let data = try ASKMCPJSONBridge.envelopeData(envelope)
        let decoder = JSONDecoder()
        switch name {
        case "quick_start":
            return .quickStart(try decoder.decode(ASKQuickStartCommand.self, from: data))
        case "index_workspace":
            return .indexWorkspace(try decoder.decode(ASKIndexWorkspaceCommand.self, from: data))
        case "import_workspace":
            return .importWorkspace(try decoder.decode(ASKImportWorkspaceCommand.self, from: data))
        case "stage_report":
            return .stageReport(try decoder.decode(ASKStageReportCommand.self, from: data))
        case "close_day":
            return .closeDay(try decoder.decode(ASKCloseDayCommand.self, from: data))
        case "import_capture":
            return .importCapture(try decoder.decode(ASKImportCaptureCommand.self, from: data))
        case "decide_patch":
            return .decidePatch(try decoder.decode(ASKDecidePatchCommand.self, from: data))
        case "repair_presentation":
            return .repairPresentation(try decoder.decode(ASKRepairPresentationCommand.self, from: data))
        case "rebuild_knowledge":
            return .rebuildKnowledge(try decoder.decode(ASKRebuildKnowledgeCommand.self, from: data))
        case "record_decision_memory":
            return .recordDecisionMemory(try decoder.decode(ASKRecordDecisionMemoryCommand.self, from: data))
        case "record_decision_memories":
            return .recordDecisionMemories(try decoder.decode(ASKRecordDecisionMemoriesCommand.self, from: data))
        case "transition_decision_memory":
            return .transitionDecisionMemory(try decoder.decode(ASKTransitionDecisionMemoryCommand.self, from: data))
        case "consolidate_decision_memory":
            return .consolidateDecisionMemory(try decoder.decode(ASKConsolidateDecisionMemoryCommand.self, from: data))
        default:
            return nil
        }
    }

    // MARK: - Queries

    private func runQuery(
        named name: String,
        arguments: [String: MCPJSONValue]
    ) async throws -> MCPCallToolResult {
        let envelope = Self.normalizedEnvelope(forTool: name, arguments: arguments)
        if let diagnostic = resourceAuthorizationDiagnostic(forTool: name, envelope: envelope, operation: .query) {
            return try failure(diagnostic)
        }
        let query: ASKQuery?
        do {
            query = try makeQuery(named: name, arguments: envelope)
        } catch {
            return try failure(decodingDiagnostic(forTool: name, operation: .query))
        }
        guard let query else {
            throw MCPRPCError(
                code: -32602,
                message: "Unknown tool",
                data: .object(["name": .string(name)])
            )
        }
        do {
            let queryResult = try await client.query(query)
            return try result(queryResult)
        } catch let diagnostic as ASKDiagnostic {
            return try failure(diagnostic)
        }
    }

    private func makeQuery(
        named name: String,
        arguments: [String: MCPJSONValue]
    ) throws -> ASKQuery? {
        let data = try ASKMCPJSONBridge.envelopeData(arguments)
        let decoder = JSONDecoder()
        switch name {
        case "search_evidence":
            return .searchEvidence(try decoder.decode(ASKEvidenceSearchQuery.self, from: data))
        case "search_knowledge":
            return .searchKnowledge(try decoder.decode(ASKKnowledgeSearchQuery.self, from: data))
        case "retrieve_evidence":
            return .retrieveEvidence(try decoder.decode(ASKEvidenceRetrieveQuery.self, from: data))
        case "projection":
            return .projection(try decoder.decode(ASKProjectionQuery.self, from: data))
        case "markdown_page":
            return .markdownPage(try decoder.decode(ASKMarkdownPageQuery.self, from: data))
        case "reading_context":
            return .readingContext(try decoder.decode(ASKReadingContextQuery.self, from: data))
        case "storage_health":
            return .storageHealth(try decoder.decode(ASKStorageHealthQuery.self, from: data))
        case "pending_work":
            return .pendingWork(try decoder.decode(ASKPendingWorkQuery.self, from: data))
        case "source_inspect":
            return .sourceInspect(try decoder.decode(ASKSourceInspectQuery.self, from: data))
        case "pending_patch":
            return .pendingPatch(try decoder.decode(ASKPendingPatchQuery.self, from: data))
        case "decision_memory":
            return .decisionMemory(try decoder.decode(ASKDecisionMemoryQuery.self, from: data))
        default:
            return nil
        }
    }

    // MARK: - Host-owned resource scope

    private func resourceAuthorizationDiagnostic(
        forTool name: String,
        envelope: [String: MCPJSONValue],
        operation: ASKOperation
    ) -> ASKDiagnostic? {
        if case .object(let workspace)? = envelope["workspace"] {
            let allowed: [(String, URL)] = [
                ("workspaceURL", configuration.workspaceURL),
                ("vaultURL", configuration.resolvedVaultURL),
                ("indexURL", configuration.resolvedIndexURL),
                ("productWorkspaceURL", configuration.resolvedProductWorkspaceURL),
            ]
            for (field, expected) in allowed {
                guard let value = workspace[field] else { continue }
                guard case .string(let raw) = value,
                      let supplied = URL(string: raw),
                      sameResource(supplied, expected) else {
                    return denied(
                        operation: operation,
                        tool: name,
                        field: "workspace.\(field)",
                        message: "MCP workspace routes are fixed by the host configuration"
                    )
                }
            }
        }

        for field in ["sourceRootURL", "captureManifestURL"] {
            guard let value = envelope[field] else { continue }
            guard case .string(let raw) = value,
                  let url = URL(string: raw),
                  isWithinReadScope(url) else {
                return denied(
                    operation: operation,
                    tool: name,
                    field: field,
                    message: "MCP external reads require a host-approved read root"
                )
            }
            if field == "captureManifestURL" {
                do {
                    let stagingRoot = try ASKClient.captureStagingRoot(for: url)
                    guard isWithinReadScope(stagingRoot) else {
                        return denied(operation: operation, tool: name, field: field,
                            message: "Capture import requires host approval for its complete staging root")
                    }
                } catch let diagnostic as ASKDiagnostic {
                    return ASKDiagnostic(code: diagnostic.code, operation: operation,
                        message: diagnostic.message, context: diagnostic.context,
                        recovery: diagnostic.recovery)
                } catch {
                    return decodingDiagnostic(forTool: name, operation: operation)
                }
            }
        }
        return nil
    }

    private func isWithinReadScope(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return ([configuration.workspaceURL] + policyConfiguration.additionalReadRoots)
            .filter(\.isFileURL)
            .contains { sameOrDescendant(url, $0) }
    }

    private func sameResource(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.isFileURL, rhs.isFileURL else { return false }
        return canonicalPath(lhs) == canonicalPath(rhs)
    }

    private func sameOrDescendant(_ child: URL, _ root: URL) -> Bool {
        guard child.isFileURL, root.isFileURL else { return false }
        let childPath = canonicalPath(child)
        let rootPath = canonicalPath(root)
        return childPath == rootPath || childPath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func denied(
        operation: ASKOperation,
        tool: String,
        field: String,
        message: String
    ) -> ASKDiagnostic {
        ASKDiagnostic(
            code: .permissionDenied,
            operation: operation,
            message: message,
            context: ["tool": tool, "field": field],
            recovery: .correctInput
        )
    }

    // MARK: - Result shaping

    private func decodingDiagnostic(
        forTool name: String,
        operation: ASKOperation
    ) -> ASKDiagnostic {
        ASKDiagnostic(
            code: .invalidRequest,
            operation: operation,
            message: "Invalid arguments for `\(name)`.",
            context: ["tool": name],
            recovery: .correctInput
        )
    }

    private func result(_ payload: some Encodable) throws -> MCPCallToolResult {
        try MCPCallToolResult(
            content: [.text(MCPTextContent(text: ASKMCPJSONBridge.text(payload)))],
            structuredContent: ASKMCPJSONBridge.structuredValue(payload)
        )
    }

    /// Typed diagnostics surface as tool results with `isError` so hosts and
    /// agents can read code, message, context, and recovery instead of seeing a
    /// protocol-level internal error. Unexpected failures keep rethrowing.
    private func failure(_ diagnostic: ASKDiagnostic) throws -> MCPCallToolResult {
        try MCPCallToolResult(
            content: [.text(MCPTextContent(text: ASKMCPJSONBridge.text(diagnostic)))],
            structuredContent: ASKMCPJSONBridge.structuredValue(diagnostic),
            isError: true
        )
    }
}
