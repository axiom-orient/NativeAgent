import Foundation

func publicError(_ error: any Error) -> AgentMemoryError {
    if let error = error as? AgentMemoryError { return error }
    if error is CancellationError {
        return AgentMemoryError(
            kind: .cancelled,
            code: "cancelled",
            message: "memory operation cancelled",
            operation: "memory.cancel"
        )
    }
    let appError = asAppError(error)
    let kind: AgentMemoryErrorKind
    switch appError.exitCode {
    case .validation: kind = .validation
    case .workspace: kind = .workspace
    case .storage: kind = .storage
    case .llm: kind = .llm
    case .internalError: kind = .internalError
    case .ok: kind = .internalError
    }
    return AgentMemoryError(
        kind: kind,
        code: appError.code,
        message: appError.message,
        cause: appError.cause,
        operation: appError.operation,
        context: appError.context
    )
}

func publicWorkspaceInfo(_ workspace: Workspace, workspaceID: String) -> AgentMemoryWorkspaceInfo {
    AgentMemoryWorkspaceInfo(
        workspaceID: workspaceID,
        dataDirectory: URL(fileURLWithPath: workspace.paths.root),
        databaseFile: URL(fileURLWithPath: workspace.paths.db)
    )
}

func publicSearchMatch(_ result: MemorySearchHit) -> AgentMemorySearchMatch {
    AgentMemorySearchMatch(
        id: result.id,
        layer: result.layer,
        type: result.kind,
        role: result.role,
        content: result.content,
        score: result.score,
        sourceMessageIDs: result.sourceMessageIDs,
        slotKey: result.slotKey,
        sourceSessionID: result.sourceSessionID
    )
}
