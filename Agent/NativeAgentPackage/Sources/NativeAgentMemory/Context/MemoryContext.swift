import Foundation

public struct MemoryScope: Sendable, Equatable, Hashable {
    public let profileID: String
    public let userID: String
    /// Stable retrieval boundary. It must not be populated from the current
    /// source session unless the host explicitly wants session isolation.
    public let namespace: String
    /// Source-session provenance/current transcript identity. Recall ignores
    /// this value by default and therefore spans all sessions in namespace.
    public let sessionKey: String

    public init(
        profileID: String = "",
        userID: String = "",
        sessionKey: String = "",
        namespace: String = ""
    ) {
        self.profileID = profileID
        self.userID = userID
        self.sessionKey = sessionKey
        self.namespace = namespace
    }
}

public enum MemoryRole: String, Sendable, Equatable, Hashable, CaseIterable {
    case user
    case assistant
    case tool
}

public enum MemoryRecordKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case fact
    case episode
    case instruction
    case workflow
    case gotcha
}

public struct MemoryTurn: Sendable, Equatable, Hashable {
    public let id: String
    public let role: MemoryRole
    public let content: String
    public let timestampMilliseconds: Int64?
    public let sessionID: String
    public let sessionKey: String
    public let toolName: String?
    public let toolCallsJSON: String?
    public let metadata: [String: String]

    public init(
        id: String = "",
        role: MemoryRole,
        content: String,
        timestampMilliseconds: Int64? = nil,
        sessionID: String = "",
        sessionKey: String = "",
        toolName: String? = nil,
        toolCallsJSON: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestampMilliseconds = timestampMilliseconds
        self.sessionID = sessionID
        self.sessionKey = sessionKey
        self.toolName = toolName
        self.toolCallsJSON = toolCallsJSON
        self.metadata = metadata
    }
}

public struct MemoryMatch: Sendable, Equatable, Hashable {
    public let id: String
    public let layer: String
    public let type: String
    public let role: String
    public let content: String
    public let score: Double
    public let slotKey: String?
    public let sourceSessionID: String
    public let sourceMessageIDs: [String]

    public init(
        id: String,
        layer: String,
        type: String = "",
        role: String = "",
        content: String,
        score: Double,
        slotKey: String? = nil,
        sourceSessionID: String = "",
        sourceMessageIDs: [String] = []
    ) {
        self.id = id
        self.layer = layer
        self.type = type
        self.role = role
        self.content = content
        self.score = score
        self.slotKey = slotKey
        self.sourceSessionID = sourceSessionID
        self.sourceMessageIDs = sourceMessageIDs
    }
}

public struct MemoryContext: Sendable, Equatable {
    public let query: String
    public let memoryContext: String
    public let matches: [MemoryMatch]

    public init(
        query: String,
        memoryContext: String,
        matches: [MemoryMatch] = []
    ) {
        self.query = query
        self.memoryContext = memoryContext
        self.matches = matches
    }

    public var isEmpty: Bool {
        memoryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && matches.isEmpty
    }

    public var systemPromptFragment: String? {
        let context = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.isEmpty == false else { return nil }
        return ["<native-agent-memory>", context, "</native-agent-memory>"].joined(separator: "\n\n")
    }
}

public struct MemoryCaptureResult: Sendable, Equatable {
    public let inputMessages: Int
    public let insertedMessages: Int
    public let filtered: Bool

    public init(inputMessages: Int, insertedMessages: Int, filtered: Bool) {
        self.inputMessages = inputMessages
        self.insertedMessages = insertedMessages
        self.filtered = filtered
    }
}

public struct MemorySyncResult: Sendable, Equatable {
    public let sessionID: String
    public let scannedMessages: Int
    public let insertedEvents: Int
    public let messageCount: Int
    public let revision: Int64

    public init(sessionID: String, scannedMessages: Int, insertedEvents: Int, messageCount: Int, revision: Int64) {
        self.sessionID = sessionID
        self.scannedMessages = scannedMessages
        self.insertedEvents = insertedEvents
        self.messageCount = messageCount
        self.revision = revision
    }
}

public struct MemorySearchQuery: Sendable, Equatable {
    public let query: String
    public let kinds: [MemoryRecordKind]
    public let fromMilliseconds: Int64?
    public let toMilliseconds: Int64?
    public let historical: Bool
    public let limit: Int

    public init(
        query: String,
        kinds: [MemoryRecordKind] = [],
        fromMilliseconds: Int64? = nil,
        toMilliseconds: Int64? = nil,
        historical: Bool = false,
        limit: Int = 8
    ) {
        self.query = query
        self.kinds = kinds
        self.fromMilliseconds = fromMilliseconds
        self.toMilliseconds = toMilliseconds
        self.historical = historical
        self.limit = limit
    }

    public var fromMS: Int64? { fromMilliseconds }
    public var toMS: Int64? { toMilliseconds }
}

public struct MemorySearchResult: Sendable, Equatable {
    public let query: String
    public let matches: [MemoryMatch]
    public let historical: Bool

    public init(query: String, matches: [MemoryMatch], historical: Bool = false) {
        self.query = query
        self.matches = matches
        self.historical = historical
    }
}

public struct MemoryConsolidationResult: Sendable, Equatable {
    public let insertedRecords: Int
    public let insertedRelations: Int
    public let closedThroughEventID: String?

    public init(insertedRecords: Int, insertedRelations: Int, closedThroughEventID: String?) {
        self.insertedRecords = insertedRecords
        self.insertedRelations = insertedRelations
        self.closedThroughEventID = closedThroughEventID
    }
}

public struct MemoryCapabilities: Sendable, Equatable {
    public let sqliteVersion: String
    public let foreignKeys: Bool
    public let strictTables: Bool
    public let fts5: Bool

    public init(sqliteVersion: String, foreignKeys: Bool, strictTables: Bool, fts5: Bool) {
        self.sqliteVersion = sqliteVersion
        self.foreignKeys = foreignKeys
        self.strictTables = strictTables
        self.fts5 = fts5
    }
}
