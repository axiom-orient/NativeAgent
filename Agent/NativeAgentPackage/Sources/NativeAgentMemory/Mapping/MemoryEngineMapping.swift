import NativeAgentDomain
internal import NativeAgentMemoryProjection
import Foundation

extension AgentMemoryScope {
    init(_ scope: MemoryScope) {
        self.init(
            profileID: scope.profileID,
            userID: scope.userID,
            namespace: scope.namespace,
            sessionKey: scope.sessionKey
        )
    }
}

extension AgentMemoryTurn {
    init(_ turn: MemoryTurn) {
        let admission = MemoryCaptureAdmission.flags(for: turn.metadata)
        self.init(
            id: turn.id,
            role: AgentMemoryRole(turn.role),
            content: turn.content,
            timestampMilliseconds: turn.timestampMilliseconds,
            sessionID: turn.sessionID,
            sessionKey: turn.sessionKey,
            toolName: turn.toolName,
            toolCallsJSON: turn.toolCallsJSON,
            isHidden: admission.isHidden,
            isSensitive: admission.isSensitive
        )
    }
}

extension AgentMemoryRole {
    init(_ role: MemoryRole) {
        switch role {
        case .user:
            self = .user
        case .assistant:
            self = .assistant
        case .tool:
            self = .tool
        }
    }
}

extension MemoryScope {
    init(_ scope: AgentMemoryScope) {
        self.init(
            profileID: scope.profileID,
            userID: scope.userID,
            sessionKey: scope.sessionKey,
            namespace: scope.namespace
        )
    }
}

extension MemoryMatch {
    init(_ match: AgentMemorySearchMatch) {
        self.init(
            id: match.id,
            layer: match.layer,
            type: match.type,
            content: match.content,
            score: match.score,
            slotKey: match.slotKey,
            sourceSessionID: match.sourceSessionID,
            sourceMessageIDs: match.sourceMessageIDs
        )
    }
}

extension MemoryMatch {
    init(_ hit: MemorySearchHit) {
        self.init(
            id: hit.id,
            layer: hit.layer,
            type: hit.kind,
            role: hit.role,
            content: hit.content,
            score: hit.score,
            slotKey: hit.slotKey,
            sourceSessionID: hit.sourceSessionID,
            sourceMessageIDs: hit.sourceMessageIDs
        )
    }
}

extension MemoryContext {
    init(_ recalled: AgentMemoryRecallResult) {
        self.init(
            query: recalled.query,
            memoryContext: recalled.prependContext,
            matches: recalled.results.map(MemoryMatch.init)
        )
    }
}

extension MemoryCapabilities {
    init(_ capabilities: AgentMemoryCapabilities) {
        self.init(
            sqliteVersion: capabilities.sqliteVersion,
            foreignKeys: capabilities.foreignKeys,
            strictTables: capabilities.strictTables,
            fts5: capabilities.fts5
        )
    }
}

extension MemoryCaptureResult {
    init(_ result: AgentMemoryIngestResult) {
        self.init(
            inputMessages: result.inputMessages,
            insertedMessages: result.insertedMessages,
            filtered: result.filtered
        )
    }
}

extension AgentMemoryRole {
    init?(_ role: AgentMessage.Role) {
        switch role {
        case .user:
            self = .user
        case .assistant:
            self = .assistant
        case .system, .tool:
            return nil
        }
    }
}
