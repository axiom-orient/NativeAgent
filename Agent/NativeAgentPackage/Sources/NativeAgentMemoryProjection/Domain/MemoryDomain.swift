import Foundation

// The v1 transcript projection deliberately stays small. These values are
// immutable inputs to Store; lifecycle and mutation remain actor/store-owned.
package enum ProjectionRecordKind: String, Codable, CaseIterable, Hashable, Sendable {
    case fact
    case episode
    case instruction
    case workflow
    case gotcha
}

package enum MemoryRelationKind: String, Codable, CaseIterable, Sendable {
    case supersedes
    case causes
    case dependsOn = "depends_on"
}

package struct MemoryEvent: Sendable, Equatable {
    package let rowID: Int64
    package let id: String
    package let workspaceID: String
    package let profileID: String
    package let userID: String
    package let namespace: String
    package let sourceSessionID: String
    package let sourceMessageID: String
    package let sourceIndex: Int?
    package let role: String
    package let content: String
    package let occurredAtMS: Int64
    package let contentHash: String
    package let metadataJSON: String

    package init(rowID: Int64, id: String, workspaceID: String, profileID: String, userID: String, namespace: String, sourceSessionID: String, sourceMessageID: String, sourceIndex: Int? = nil, role: String, content: String, occurredAtMS: Int64, contentHash: String, metadataJSON: String) {
        self.rowID = rowID; self.id = id; self.workspaceID = workspaceID; self.profileID = profileID; self.userID = userID; self.namespace = namespace; self.sourceSessionID = sourceSessionID; self.sourceMessageID = sourceMessageID; self.sourceIndex = sourceIndex; self.role = role; self.content = content; self.occurredAtMS = occurredAtMS; self.contentHash = contentHash; self.metadataJSON = metadataJSON
    }
}

package struct MemoryRecord: Sendable, Equatable {
    package let rowID: Int64
    package let id: String
    package let workspaceID: String
    package let profileID: String
    package let userID: String
    package let namespace: String
    package let sourceSessionID: String
    package let kind: ProjectionRecordKind
    package let slotKey: String?
    package let content: String
    package let validFromMS: Int64?
    package let createdAtMS: Int64
    package let contentHash: String

    package init(rowID: Int64, id: String, workspaceID: String, profileID: String, userID: String, namespace: String, sourceSessionID: String, kind: ProjectionRecordKind, slotKey: String?, content: String, validFromMS: Int64?, createdAtMS: Int64, contentHash: String) {
        self.rowID = rowID; self.id = id; self.workspaceID = workspaceID; self.profileID = profileID; self.userID = userID; self.namespace = namespace; self.sourceSessionID = sourceSessionID; self.kind = kind; self.slotKey = slotKey; self.content = content; self.validFromMS = validFromMS; self.createdAtMS = createdAtMS; self.contentHash = contentHash
    }
}

package struct MemoryEvidence: Sendable, Equatable {
    package let recordID: String
    package let eventID: String
    package let quote: String
    package init(recordID: String, eventID: String, quote: String) { self.recordID = recordID; self.eventID = eventID; self.quote = quote }
}

package struct MemoryRelation: Sendable, Equatable {
    package let fromRecordID: String
    package let relation: MemoryRelationKind
    package let toRecordID: String
    package init(fromRecordID: String, relation: MemoryRelationKind, toRecordID: String) { self.fromRecordID = fromRecordID; self.relation = relation; self.toRecordID = toRecordID }
}

package struct MemoryCheckpoint: Sendable, Equatable {
    package let workspaceID: String
    package let profileID: String
    package let userID: String
    package let namespace: String
    package let sourceSessionID: String
    package let messageCount: Int
    package let agentRevision: Int64
    package let consolidatedRowID: Int64
    package let lastSourceMessageID: String
    package let lastSourceContentHash: String
    package let lastSourceRole: String
    package let lastSourceOccurredAtMS: Int64

    package init(workspaceID: String, profileID: String, userID: String, namespace: String, sourceSessionID: String, messageCount: Int, agentRevision: Int64, consolidatedRowID: Int64, lastSourceMessageID: String, lastSourceContentHash: String, lastSourceRole: String, lastSourceOccurredAtMS: Int64) {
        self.workspaceID = workspaceID; self.profileID = profileID; self.userID = userID; self.namespace = namespace; self.sourceSessionID = sourceSessionID; self.messageCount = messageCount; self.agentRevision = agentRevision; self.consolidatedRowID = consolidatedRowID; self.lastSourceMessageID = lastSourceMessageID; self.lastSourceContentHash = lastSourceContentHash; self.lastSourceRole = lastSourceRole; self.lastSourceOccurredAtMS = lastSourceOccurredAtMS
    }
}

package struct AgentMemoryJournalState: Sendable, Equatable {
    package let messageCount: Int
    package let revision: Int64
    package init(messageCount: Int, revision: Int64) { self.messageCount = messageCount; self.revision = revision }
}

package struct AgentMemoryIncomingMessage: Sendable, Equatable {
    package let id: String
    package let role: String
    package let content: String
    package let occurredAtMS: Int64
    package let toolName: String?
    package let toolCallsJSON: String?
    package let sourceIndex: Int?
    package let isHidden: Bool
    package let isSensitive: Bool
    package let rawContentHash: String
    package init(id: String, role: String, content: String, occurredAtMS: Int64, toolName: String? = nil, toolCallsJSON: String? = nil, sourceIndex: Int? = nil, isHidden: Bool = false, isSensitive: Bool = false, rawContentHash: String) { self.id = id; self.role = role; self.content = content; self.occurredAtMS = occurredAtMS; self.toolName = toolName; self.toolCallsJSON = toolCallsJSON; self.sourceIndex = sourceIndex; self.isHidden = isHidden; self.isSensitive = isSensitive; self.rawContentHash = rawContentHash }
}

package struct AgentMemorySyncPlan: Sendable, Equatable {
    package let offset: Int
    package let messageCount: Int
    package let revision: Int64
    package let noOp: Bool
    package init(offset: Int, messageCount: Int, revision: Int64, noOp: Bool) { self.offset = offset; self.messageCount = messageCount; self.revision = revision; self.noOp = noOp }
}

package struct AgentMemoryIncomingPage: Sendable, Equatable {
    package let offset: Int
    package let totalCount: Int
    package let messages: [AgentMemoryIncomingMessage]
    package init(offset: Int, totalCount: Int, messages: [AgentMemoryIncomingMessage]) { self.offset = offset; self.totalCount = totalCount; self.messages = messages }
}

package struct AgentMemorySyncResult: Sendable, Equatable {
    package let scannedMessages: Int
    package let insertedEvents: Int
    package let messageCount: Int
    package let revision: Int64
    package init(scannedMessages: Int, insertedEvents: Int, messageCount: Int, revision: Int64) { self.scannedMessages = scannedMessages; self.insertedEvents = insertedEvents; self.messageCount = messageCount; self.revision = revision }
}

package struct ProjectionSearchQuery: Sendable, Equatable {
    package let query: String
    package let kinds: Set<ProjectionRecordKind>
    package let fromMS: Int64?
    package let toMS: Int64?
    package let historical: Bool
    package let limit: Int
    package init(query: String, kinds: Set<ProjectionRecordKind>, fromMS: Int64?, toMS: Int64?, historical: Bool, limit: Int) { self.query = query; self.kinds = kinds; self.fromMS = fromMS; self.toMS = toMS; self.historical = historical; self.limit = limit }
}

package struct MemorySearchHit: Sendable, Equatable {
    package let id: String
    package let layer: String
    package let kind: String
    package let role: String
    package let content: String
    package let score: Double
    package let sourceSessionID: String
    package let sourceMessageIDs: [String]
    package let slotKey: String?
    package init(id: String, layer: String, kind: String, role: String, content: String, score: Double, sourceSessionID: String, sourceMessageIDs: [String], slotKey: String?) { self.id = id; self.layer = layer; self.kind = kind; self.role = role; self.content = content; self.score = score; self.sourceSessionID = sourceSessionID; self.sourceMessageIDs = sourceMessageIDs; self.slotKey = slotKey }
}

package struct ProjectionConsolidationResult: Sendable, Equatable {
    package let insertedRecords: Int
    package let insertedRelations: Int
    package let closedThroughEventID: String?
    package init(insertedRecords: Int, insertedRelations: Int, closedThroughEventID: String?) { self.insertedRecords = insertedRecords; self.insertedRelations = insertedRelations; self.closedThroughEventID = closedThroughEventID }
}
