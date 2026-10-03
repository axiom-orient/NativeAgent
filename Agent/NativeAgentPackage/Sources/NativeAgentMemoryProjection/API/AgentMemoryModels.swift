import Foundation

package enum AgentMemoryErrorKind: String, Sendable, Equatable {
    case validation
    case workspace
    case storage
    case llm
    case internalError
    case cancelled
}

package struct AgentMemoryError: Error, CustomStringConvertible, Sendable, Equatable {
    package let kind: AgentMemoryErrorKind
    package let code: String
    package let message: String
    package let cause: String?
    package let operation: String
    package let context: [String: String]

    package init(
        kind: AgentMemoryErrorKind,
        code: String,
        message: String,
        cause: String? = nil,
        operation: String? = nil,
        context: [String: String] = [:]
    ) {
        self.kind = kind
        self.code = code
        self.message = message
        self.cause = cause
        self.operation = operation ?? code
        self.context = context
    }

    package var description: String {
        guard let cause else { return "\(code): \(message)" }
        return "\(code): \(message): \(cause)"
    }
}

package enum AgentMemoryRole: String, Sendable, Equatable {
    case user
    case assistant
    case tool
}


package struct AgentMemoryCapabilities: Sendable, Equatable {
    package let sqliteVersion: String
    package let foreignKeys: Bool
    package let strictTables: Bool
    package let fts5: Bool

    package init(sqliteVersion: String, foreignKeys: Bool, strictTables: Bool, fts5: Bool) {
        self.sqliteVersion = sqliteVersion
        self.foreignKeys = foreignKeys
        self.strictTables = strictTables
        self.fts5 = fts5
    }
}

package struct AgentMemoryConfiguration: Sendable, Equatable {
    package let dataDirectory: URL
    package let defaultProfileID: String
    package let defaultUserID: String
    package let namespace: String

    package init(
        dataDirectory: URL,
        defaultProfileID: String = "default",
        defaultUserID: String = "default",
        namespace: String = ""
    ) {
        self.dataDirectory = dataDirectory
        self.defaultProfileID = defaultProfileID
        self.defaultUserID = defaultUserID
        self.namespace = namespace
    }
}

package struct AgentMemoryWorkspaceInfo: Sendable, Equatable {
    package let workspaceID: String
    package let dataDirectory: URL
    package let databaseFile: URL
}

package struct AgentMemoryScope: Sendable, Equatable {
    package let profileID: String
    package let userID: String
    package let namespace: String
    package let sessionKey: String

    package init(
        profileID: String = "",
        userID: String = "",
        namespace: String = "",
        sessionKey: String = ""
    ) {
        self.profileID = profileID
        self.userID = userID
        self.namespace = namespace
        self.sessionKey = sessionKey
    }
}

package struct AgentMemoryTurn: Sendable, Equatable {
    package let id: String
    package let role: AgentMemoryRole
    package let content: String
    package let timestampMilliseconds: Int64?
    package let sessionID: String
    package let sessionKey: String
    package let toolName: String?
    package let toolCallsJSON: String?
    package let isHidden: Bool
    package let isSensitive: Bool

    package init(
        id: String = "",
        role: AgentMemoryRole,
        content: String,
        timestampMilliseconds: Int64? = nil,
        sessionID: String = "",
        sessionKey: String = "",
        toolName: String? = nil,
        toolCallsJSON: String? = nil,
        isHidden: Bool = false,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestampMilliseconds = timestampMilliseconds
        self.sessionID = sessionID
        self.sessionKey = sessionKey
        self.toolName = toolName
        self.toolCallsJSON = toolCallsJSON
        self.isHidden = isHidden
        self.isSensitive = isSensitive
    }
}


package struct AgentMemoryIngestResult: Sendable, Equatable {
    package let inputMessages: Int
    package let insertedMessages: Int
    package let filtered: Bool
}


package struct AgentMemorySearchMatch: Sendable, Equatable {
    package let id: String
    package let layer: String
    package let type: String
    package let role: String
    package let content: String
    package let score: Double
    package let sourceMessageIDs: [String]
    package let slotKey: String?
    package let sourceSessionID: String

    package init(
        id: String,
        layer: String,
        type: String = "",
        role: String = "",
        content: String,
        score: Double,
        sourceMessageIDs: [String] = [],
        slotKey: String? = nil,
        sourceSessionID: String = ""
    ) {
        self.id = id
        self.layer = layer
        self.type = type
        self.role = role
        self.content = content
        self.score = score
        self.sourceMessageIDs = sourceMessageIDs
        self.slotKey = slotKey
        self.sourceSessionID = sourceSessionID
    }
}

package struct AgentMemoryRecallResult: Sendable, Equatable {
    package let query: String
    package let results: [AgentMemorySearchMatch]
    package let prependContext: String
}
