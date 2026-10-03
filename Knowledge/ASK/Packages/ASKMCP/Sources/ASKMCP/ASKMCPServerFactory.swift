import ASK
import Foundation
import MCP

/// Builds a stateless MCP server that exposes the canonical ASK typed
/// boundary. The runtime validates every `tools/call` against the catalog
/// schema (unknown fields fail closed) before the dispatcher runs.
public enum ASKMCPServerFactory {
    public static let implementationName = "ask-mcp"
    public static let implementationVersion = "0.1.0"

    public static func makeServer(
        configuration: ASKConfiguration,
        implementation: MCPImplementation? = nil,
        instructions: String? = defaultInstructions
    ) throws -> MCPServer {
        try makeServer(
            configuration: configuration,
            policyConfiguration: ASKMCPPolicyConfiguration(policy: .readOnly),
            implementation: implementation,
            instructions: instructions
        )
    }

    /// Policy-gated variant. `read-only` and `staging` hide the approval tool
    /// entirely; `.full` requires an operator identity that is force-injected
    /// into every approval.
    public static func makeServer(
        configuration: ASKConfiguration,
        policyConfiguration: ASKMCPPolicyConfiguration,
        implementation: MCPImplementation? = nil,
        instructions: String? = defaultInstructions
    ) throws -> MCPServer {
        guard !policyConfiguration.policy.requiresOperatorIdentity
            || policyConfiguration.resolvedOperatorIdentity != nil
        else {
            throw ASKMCPPolicyError.missingOperatorIdentity
        }
        let resolvedImplementation = try implementation ?? MCPImplementation(
            name: implementationName,
            version: implementationVersion,
            description: "Typed local-knowledge tools for the ASK knowledge engine."
        )
        var builder = try MCPServerBuilder(
            implementation: resolvedImplementation,
            instructions: instructions
        )
        let catalog = try ASKMCPToolCatalog(policy: policyConfiguration.policy)
        let dispatcher = try ASKMCPRequestDispatcher(
            configuration: configuration,
            catalog: catalog,
            policyConfiguration: policyConfiguration
        )

        builder.setToolResolver { name, _ in
            catalog.tool(named: name)
        }
        try builder.register(MCPStandardMethods.listTools) { _, _ in
            MCPListToolsResult(tools: catalog.tools)
        }
        try builder.register(MCPStandardMethods.callTool) { params, _ in
            try await dispatcher.callTool(name: params.name, arguments: params.arguments)
        }
        return try builder.build()
    }

    public static let defaultInstructions = """
    ASK is an evidence-backed local knowledge engine. Every effecting command \
    builds a deterministic plan, verifies it, and applies it through one \
    workspace mutation lane; committed changes live in a replayable journal. \
    Use index_workspace to ingest sources without committing knowledge, then stage_report, \
    pending_patch, and decide_patch for reviewable changes. Use retrieve_evidence and \
    source_inspect to verify source identity and raw evidence. Use dryRunOnly=true to \
    preview commands without effects, and pending_work to discover staged work and repairs.
    """
}
