import NativeAgentDomain
import LanguageModelCore
import Foundation

public enum AgentProjectionError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(String)
    case unknownFields([String])
    case invalidValue(String)
    case oversized
    case staleRevision
    case revisionConflict

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported projection version: \(version)."
        case .unknownFields(let fields): return "Projection contains unknown fields: \(fields.sorted().joined(separator: ", "))."
        case .invalidValue(let message): return message
        case .oversized: return "Projection exceeds the presentation bounds."
        case .staleRevision: return "Projection revision is older than the hydrated value."
        case .revisionConflict: return "Projection revision conflicts with different presentation data."
        }
    }
}

public struct AgentJournalRecord: Codable, Sendable, Equatable {
    public static let currentVersion = "native-agent.journal/1"
    public static let maximumDocumentBytes = 64 * 1_024

    public let version: String
    public let recordID: String
    public let sessionID: String
    public let revision: Int64
    public let status: SessionStatus
    public let updatedAt: Date
    public let messageCount: Int
    public let artifactCount: Int

    public init(
        sessionID: String,
        revision: Int64,
        status: SessionStatus,
        updatedAt: Date,
        messageCount: Int,
        artifactCount: Int
    ) throws {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 128,
              revision >= 0,
              messageCount >= 0, messageCount <= 1_000_000,
              artifactCount >= 0, artifactCount <= 1_000_000,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AgentProjectionError.invalidValue("Journal record identity or counts are invalid.")
        }
        version = Self.currentVersion
        recordID = "native-agent.journal/1:\(sessionID):\(revision)"
        self.sessionID = sessionID
        self.revision = revision
        self.status = status
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.artifactCount = artifactCount
    }

    public func encodedDocument() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumDocumentBytes else { throw AgentProjectionError.oversized }
        return data
    }

    public static func decodeDocument(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumDocumentBytes else {
            throw AgentProjectionError.oversized
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, recordID, sessionID, revision, status, updatedAt, messageCount, artifactCount
    }

    public init(from decoder: any Decoder) throws {
        try Self.rejectUnknownFields(decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(String.self, forKey: .version)
        guard version == Self.currentVersion else { throw AgentProjectionError.unsupportedVersion(version) }
        let record = try Self.init(
            sessionID: values.decode(String.self, forKey: .sessionID),
            revision: values.decode(Int64.self, forKey: .revision),
            status: values.decode(SessionStatus.self, forKey: .status),
            updatedAt: values.decode(Date.self, forKey: .updatedAt),
            messageCount: values.decode(Int.self, forKey: .messageCount),
            artifactCount: values.decode(Int.self, forKey: .artifactCount)
        )
        guard try values.decode(String.self, forKey: .recordID) == record.recordID else {
            throw AgentProjectionError.invalidValue("Journal record identity does not match its canonical fields.")
        }
        self = record
    }

    private static func rejectUnknownFields(_ decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: ProjectionCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
        guard unknown.isEmpty else { throw AgentProjectionError.unknownFields(unknown) }
    }
}

public struct AgentCloudProjection: Codable, Sendable, Equatable {
    public static let currentVersion = "native-agent.cloud-projection/1"
    public static let maximumMessages = 50
    public static let maximumTextBytes = 256 * 1_024
    public static let maximumDocumentBytes = 512 * 1_024

    public struct Message: Codable, Sendable, Equatable {
        public let id: String
        public let role: String
        public let text: String
        public let createdAt: Date

        public init(id: String, role: String, text: String, createdAt: Date) throws {
            guard !id.isEmpty, id.utf8.count <= 128,
                  role == "user" || role == "assistant" || role == "system" || role == "tool",
                  text.utf8.count <= 16 * 1_024,
                  createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw AgentProjectionError.invalidValue("Cloud message is outside the presentation contract.")
            }
            self.id = id
            self.role = role
            self.text = text
            self.createdAt = createdAt
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, role, text, createdAt
        }

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.container(keyedBy: ProjectionCodingKey.self)
            let allowed = Set(CodingKeys.allCases.map(\.rawValue))
            let unknown = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
            guard unknown.isEmpty else { throw AgentProjectionError.unknownFields(unknown) }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self = try Self.init(
                id: values.decode(String.self, forKey: .id),
                role: values.decode(String.self, forKey: .role),
                text: values.decode(String.self, forKey: .text),
                createdAt: values.decode(Date.self, forKey: .createdAt)
            )
        }
    }

    public let version: String
    public let projectionID: String
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
    public let messages: [Message]

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
        artifactCount: Int,
        messages: [Message]
    ) throws {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 128, revision >= 0,
              messageCount >= 0, messageCount <= 1_000_000,
              artifactCount >= 0, artifactCount <= 1_000_000,
              messages.count <= Self.maximumMessages,
              title?.utf8.count ?? 0 <= 1_024,
              providerID?.utf8.count ?? 0 <= 128,
              modelID?.utf8.count ?? 0 <= 256,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              messages.reduce(0, { $0 + $1.text.utf8.count }) <= Self.maximumTextBytes else {
            throw AgentProjectionError.oversized
        }
        version = Self.currentVersion
        projectionID = "native-agent.cloud-projection/1:\(sessionID):\(revision)"
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
        self.messages = messages
    }

    public func encodedDocument() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumDocumentBytes else { throw AgentProjectionError.oversized }
        return data
    }

    public static func decodeDocument(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumDocumentBytes else {
            throw AgentProjectionError.oversized
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, projectionID, sessionID, revision, title, status, createdAt, updatedAt
        case providerID, modelID, messageCount, artifactCount, messages
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: ProjectionCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
        guard unknown.isEmpty else { throw AgentProjectionError.unknownFields(unknown) }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(String.self, forKey: .version)
        guard version == Self.currentVersion else { throw AgentProjectionError.unsupportedVersion(version) }
        let projection = try Self.init(
            sessionID: values.decode(String.self, forKey: .sessionID),
            revision: values.decode(Int64.self, forKey: .revision),
            title: values.decodeIfPresent(String.self, forKey: .title),
            status: values.decode(SessionStatus.self, forKey: .status),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt),
            providerID: values.decodeIfPresent(String.self, forKey: .providerID),
            modelID: values.decodeIfPresent(String.self, forKey: .modelID),
            messageCount: values.decode(Int.self, forKey: .messageCount),
            artifactCount: values.decode(Int.self, forKey: .artifactCount),
            messages: values.decode([Message].self, forKey: .messages)
        )
        guard try values.decode(String.self, forKey: .projectionID) == projection.projectionID else {
            throw AgentProjectionError.invalidValue("Cloud projection identity does not match its canonical fields.")
        }
        self = projection
    }
}

/// Presentation-only hydration. This value cannot be converted into a SessionStore,
/// SessionSnapshot, effect, claim, approval, or executable Agent.
public actor AgentCloudProjectionHydrator {
    public enum Result: Sendable, Equatable { case inserted, unchanged, replaced }
    private var values: [String: AgentCloudProjection] = [:]

    public init() {}

    public func hydrate(_ projection: AgentCloudProjection) throws -> Result {
        guard let current = values[projection.sessionID] else {
            values[projection.sessionID] = projection
            return .inserted
        }
        if current.revision > projection.revision { throw AgentProjectionError.staleRevision }
        if current.revision == projection.revision {
            guard current == projection else { throw AgentProjectionError.revisionConflict }
            return .unchanged
        }
        values[projection.sessionID] = projection
        return .replaced
    }

    public func projection(sessionID: String) -> AgentCloudProjection? { values[sessionID] }
}

private struct ProjectionCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
