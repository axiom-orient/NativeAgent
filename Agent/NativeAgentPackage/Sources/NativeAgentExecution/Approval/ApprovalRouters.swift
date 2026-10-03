import Foundation
import NativeAgentDomain

public struct AllowAllApprovalRouter: ApprovalRouter {
    public init() {}

    public func resolve(request: ApprovalRequest) async -> ApprovalDecision {
        .approved(reason: "automatic")
    }
}

public struct DenyAllApprovalRouter: ApprovalRouter {
    public init() {}

    public func resolve(request: ApprovalRequest) async -> ApprovalDecision {
        .denied(reason: "denied_by_router")
    }
}

public struct ClosureApprovalRouter: ApprovalRouter {
    private let closure: @Sendable (ApprovalRequest) async -> ApprovalDecision

    public init(
        closure: @escaping @Sendable (ApprovalRequest) async -> ApprovalDecision
    ) {
        self.closure = closure
    }

    public func resolve(request: ApprovalRequest) async -> ApprovalDecision {
        await closure(request)
    }
}
