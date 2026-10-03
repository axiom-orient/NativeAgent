import ASK
import Foundation

/// Startup-time write policy for exposing ASK contracts over MCP.
///
/// The policy is an operator-owned process flag, never a model-settable
/// argument: prompt injection can forge any in-band confirmation, so the only
/// durable boundary is one chosen before the session starts. Gated tools are
/// omitted from `tools/list` and rejected at dispatch as unknown, matching the
/// double barrier used by reference MCP servers.
public enum ASKMCPPolicy: String, Sendable, CaseIterable {
    /// Read-only queries. The safe default for untrusted sessions.
    case readOnly = "read-only"
    /// Staging writes plus queries. The approval gate (`decide_patch`) and
    /// bundled auto-commit workflows stay hidden, but proposal/staging,
    /// repair, rebuild, and decision-memory effects are executable.
    case staging
    /// Everything, including bundled commit workflows and `decide_patch`.
    /// Requires an operator identity, which is force-injected into approvals
    /// regardless of model input.
    case full

    public init(parsing raw: String?) throws {
        guard let raw else {
            self = .readOnly
            return
        }
        guard let policy = ASKMCPPolicy(rawValue: raw) else {
            throw ASKMCPPolicyError.unknownPolicy(raw)
        }
        self = policy
    }

    public var allowedToolNames: Set<String> {
        switch self {
        case .readOnly:
            return ASKToolSurface.queryTools
        case .staging:
            return ASKToolSurface.queryTools
                .union(ASKToolSurface.commandTools)
                .subtracting(ASKToolSurface.bundledCommitTools)
        case .full:
            return ASKToolSurface.queryTools
                .union(ASKToolSurface.commandTools)
                .union([ASKToolSurface.approvalTool])
        }
    }

    public var requiresOperatorIdentity: Bool {
        self == .full
    }
}

public enum ASKMCPPolicyError: Error, Equatable, Sendable {
    case unknownPolicy(String)
    case missingOperatorIdentity
}

/// Canonical grouping of the typed contract tools by exposure risk.
public enum ASKToolSurface {
    public static let queryTools: Set<String> = [
        "search_evidence", "search_knowledge", "retrieve_evidence", "projection", "markdown_page",
        "reading_context", "storage_health", "pending_work", "source_inspect",
        "pending_patch", "decision_memory",
    ]
    public static let commandTools: Set<String> = [
        "quick_start", "index_workspace", "import_workspace", "stage_report", "close_day",
        "import_capture", "repair_presentation", "rebuild_knowledge",
        "record_decision_memory", "record_decision_memories", "transition_decision_memory",
        "consolidate_decision_memory",
    ]
    /// The explicit patch approval action; gated behind `.full`. Bundled
    /// commands that commit canonical state are gated by the dispatcher too.
    public static let approvalTool = "decide_patch"
    public static let bundledCommitTools: Set<String> = [
        "quick_start", "import_workspace", approvalTool,
    ]

    public static let allTools: Set<String> = queryTools.union(commandTools).union([approvalTool])
}

public struct ASKMCPPolicyConfiguration: Sendable {
    public let policy: ASKMCPPolicy
    /// Human operator bound to approvals in `.full` mode. Force-injected into
    /// approval `decidedBy`, overriding whatever the model supplied.
    public let operatorIdentity: String?
    /// Host-owned roots from which MCP callers may read external source material.
    /// The workspace itself is always readable; model arguments cannot expand this list.
    public let additionalReadRoots: [URL]

    public init(
        policy: ASKMCPPolicy,
        operatorIdentity: String? = nil,
        additionalReadRoots: [URL] = []
    ) {
        self.policy = policy
        self.operatorIdentity = operatorIdentity
        self.additionalReadRoots = additionalReadRoots.map { $0.standardizedFileURL }
    }

    public var resolvedOperatorIdentity: String? {
        guard policy == .full,
              let operatorIdentity,
              !operatorIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return operatorIdentity
    }
}
