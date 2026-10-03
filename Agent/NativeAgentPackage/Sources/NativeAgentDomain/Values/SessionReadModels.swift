import LanguageModelCore
import Foundation

private func nextPageOffset(offset: Int, totalCount: Int, itemCount: Int) -> Int? {
    let (next, overflow) = offset.addingReportingOverflow(itemCount)
    return !overflow && next < totalCount ? next : nil
}

public enum SessionReadLimits {
    public static let maximumPageSize = 500
    public static let maximumQueryLimit = 1_000
    public static let maximumQuerySessionIDs = 1_000
    public static let maximumQueryKeywords = 100
    public static let maximumQueryKeywordUTF8Bytes = 4_096

    public static func validatePage(limit: Int, offset: Int) throws {
        guard (1...maximumPageSize).contains(limit) else {
            throw AgentError.invalidConfiguration(
                "Session page limit must be between 1 and \(maximumPageSize)."
            )
        }
        guard offset >= 0 else {
            throw AgentError.invalidConfiguration(
                "Session page offset must be nonnegative."
            )
        }
    }

    public static func validated(_ query: SessionListQuery) throws -> SessionListQuery {
        let keywords = try validateQueryFields(
            sessionIDs: query.sessionIDs,
            keywords: query.keywords,
            startDate: query.startDate,
            endDate: query.endDate,
            limit: query.limit,
            offset: query.offset
        )
        return SessionListQuery(
            sessionIDs: query.sessionIDs,
            keywords: keywords,
            startDate: query.startDate,
            endDate: query.endDate,
            limit: query.limit,
            offset: query.offset
        )
    }

    public static func validated(
        _ query: SessionMessageSearchQuery
    ) throws -> SessionMessageSearchQuery {
        let keywords = try validateQueryFields(
            sessionIDs: query.sessionIDs,
            keywords: query.keywords,
            startDate: query.startDate,
            endDate: query.endDate,
            limit: query.limit,
            offset: query.offset
        )
        return SessionMessageSearchQuery(
            sessionIDs: query.sessionIDs,
            keywords: keywords,
            startDate: query.startDate,
            endDate: query.endDate,
            limit: query.limit,
            offset: query.offset
        )
    }

    private static func validateQueryFields(
        sessionIDs: [String]?,
        keywords: [String],
        startDate: Date?,
        endDate: Date?,
        limit: Int,
        offset: Int
    ) throws -> [String] {
        guard (1...maximumQueryLimit).contains(limit) else {
            throw AgentError.invalidConfiguration(
                "Session query limit must be between 1 and \(maximumQueryLimit)."
            )
        }
        guard offset >= 0 else {
            throw AgentError.invalidConfiguration(
                "Session query offset must be nonnegative."
            )
        }
        guard sessionIDs == nil || sessionIDs!.count <= maximumQuerySessionIDs else {
            throw AgentError.invalidConfiguration(
                "Session query ID count must not exceed \(maximumQuerySessionIDs)."
            )
        }
        guard startDate?.timeIntervalSince1970.isFinite != false,
              endDate?.timeIntervalSince1970.isFinite != false else {
            throw AgentError.invalidConfiguration(
                "Session query dates must be finite."
            )
        }
        if let startDate, let endDate, startDate > endDate {
            throw AgentError.invalidConfiguration(
                "Session query start date must not be after its end date."
            )
        }

        let normalized = keywords.compactMap { keyword in
            let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard normalized.count <= maximumQueryKeywords else {
            throw AgentError.invalidConfiguration(
                "Session query keyword count must not exceed \(maximumQueryKeywords)."
            )
        }
        guard normalized.allSatisfy({ $0.utf8.count <= maximumQueryKeywordUTF8Bytes }) else {
            throw AgentError.invalidConfiguration(
                "Session query keywords must not exceed \(maximumQueryKeywordUTF8Bytes) UTF-8 bytes."
            )
        }
        return normalized
    }
}

public struct SessionListQuery: Sendable, Equatable {
    public let sessionIDs: [String]?
    public let keywords: [String]
    public let startDate: Date?
    public let endDate: Date?
    public let limit: Int
    public let offset: Int

    public init(
        sessionIDs: [String]? = nil,
        keywords: [String] = [],
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.sessionIDs = sessionIDs
        self.keywords = keywords
        self.startDate = startDate
        self.endDate = endDate
        self.limit = limit
        self.offset = offset
    }
}

public struct SessionListItem: Sendable, Equatable {
    public let summary: SessionSummary
    public let preview: String?
    public let source: String?

    public init(
        summary: SessionSummary,
        preview: String?,
        source: String?
    ) {
        self.summary = summary
        self.preview = preview
        self.source = source
    }
}

public struct SessionMessageSearchQuery: Sendable, Equatable {
    public let sessionIDs: [String]?
    public let keywords: [String]
    public let startDate: Date?
    public let endDate: Date?
    public let limit: Int
    public let offset: Int

    public init(
        sessionIDs: [String]? = nil,
        keywords: [String] = [],
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.sessionIDs = sessionIDs
        self.keywords = keywords
        self.startDate = startDate
        self.endDate = endDate
        self.limit = limit
        self.offset = offset
    }
}

public struct SessionMessageSearchMatch: Sendable, Equatable {
    public let sessionID: String
    public let sessionTitle: String?
    public let message: AgentMessage

    public init(
        sessionID: String,
        sessionTitle: String?,
        message: AgentMessage
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.message = message
    }
}

public struct SessionMessageSearchPage: Sendable, Equatable {
    public let totalCount: Int
    public let offset: Int
    public let matches: [SessionMessageSearchMatch]

    public init(
        totalCount: Int,
        offset: Int,
        matches: [SessionMessageSearchMatch]
    ) {
        self.totalCount = totalCount
        self.offset = offset
        self.matches = matches
    }

    public var nextOffset: Int? {
        nextPageOffset(offset: offset, totalCount: totalCount, itemCount: matches.count)
    }
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let revision: Int64
    public let title: String?
    public let status: SessionStatus
    public let createdAt: Date
    public let updatedAt: Date
    public let providerID: String?
    public let modelID: String?
    public let messageCount: Int
    public let artifactCount: Int

    public var id: String { sessionID }

    public init(
        sessionID: String,
        revision: Int64,
        title: String?,
        status: SessionStatus,
        createdAt: Date,
        updatedAt: Date,
        providerID: String?,
        modelID: String?,
        messageCount: Int,
        artifactCount: Int
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerID = providerID
        self.modelID = modelID
        self.messageCount = messageCount
        self.artifactCount = artifactCount
    }

    public init(snapshot: SessionSnapshot) {
        self.init(
            sessionID: snapshot.sessionID,
            revision: snapshot.revision,
            title: snapshot.title,
            status: snapshot.status,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            providerID: snapshot.providerID,
            modelID: snapshot.modelID,
            messageCount: snapshot.messages.count,
            artifactCount: snapshot.artifacts.count
        )
    }
}

/// Bounded scalar state for presentation. It deliberately excludes transcript,
/// artifacts, effects, claims, approvals, and executable handles.
public struct SessionStateView: Codable, Sendable, Equatable {
    public let summary: SessionSummary
    public let metadata: [String: JSONValue]
    public let contextCheckpoint: SessionContextCheckpoint?
    public let waitState: SessionWaitState?
    public let failure: SessionFailure?
    public let lastSignal: SessionSignal?

    public init(
        summary: SessionSummary,
        metadata: [String: JSONValue],
        contextCheckpoint: SessionContextCheckpoint?,
        waitState: SessionWaitState?,
        failure: SessionFailure?,
        lastSignal: SessionSignal?
    ) {
        self.summary = summary
        self.metadata = metadata
        self.contextCheckpoint = contextCheckpoint
        self.waitState = waitState
        self.failure = failure
        self.lastSignal = lastSignal
    }
}

public struct SessionMessagePage: Codable, Sendable, Equatable {
    public let sessionID: String
    public let offset: Int
    public let totalCount: Int
    public let messages: [AgentMessage]

    public init(
        sessionID: String,
        offset: Int,
        totalCount: Int,
        messages: [AgentMessage]
    ) {
        self.sessionID = sessionID
        self.offset = offset
        self.totalCount = totalCount
        self.messages = messages
    }

    public var nextOffset: Int? {
        nextPageOffset(offset: offset, totalCount: totalCount, itemCount: messages.count)
    }
}

extension SessionSnapshot {
    /// Latest non-empty assistant output that belongs to the current user turn.
    /// Older assistant messages are never surfaced as the result of a later
    /// waiting, failed, or uncertain advancement.
    package var currentTurnAssistantContent: String? {
        guard let userIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return nil
        }
        let firstCurrentIndex = messages.index(after: userIndex)
        guard firstCurrentIndex < messages.endIndex else { return nil }
        return messages[firstCurrentIndex...].last(where: { message in
            message.role == .assistant && message.content.isEmpty == false
        })?.content
    }
}
