import NativeAgentDomain
import NativeAgentExecution

/// Application-owned approval policy for tools declared with
/// `ApprovalPolicy.requireApproval`.
public struct AgentApproval: Sendable {
    package let router: any ApprovalRouter

    private init(router: any ApprovalRouter) {
        self.router = router
    }

    /// Fail closed when the application has no approval surface.
    public static var denyAll: AgentApproval {
        AgentApproval(router: DenyAllApprovalRouter())
    }

    /// Approve every requested tool. Use only for a fully trusted tool set.
    public static var allowAll: AgentApproval {
        AgentApproval(router: AllowAllApprovalRouter())
    }

    /// Resolve approval in application code without coupling NativeAgent to UI state.
    public static func handler(
        _ handler: @escaping @Sendable (ApprovalRequest) async -> ApprovalDecision
    ) -> AgentApproval {
        AgentApproval(router: ClosureApprovalRouter(closure: handler))
    }

    /// Supply an advanced approval router implementation.
    public static func custom(_ router: any ApprovalRouter) -> AgentApproval {
        AgentApproval(router: router)
    }
}
