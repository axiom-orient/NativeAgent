import LanguageModelCore
import Foundation

public struct SessionEventKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let sessionCreated: SessionEventKind = "session.created"
    public static let snapshotSaved: SessionEventKind = "snapshot.saved"
    public static let assistantTurnAppended: SessionEventKind = "assistant_turn.appended"
    public static let waitEntered: SessionEventKind = "wait.entered"
    public static let waitCleared: SessionEventKind = "wait.cleared"
    public static let approvalResolved: SessionEventKind = "approval.resolved"
    public static let modelInvocationResolved: SessionEventKind = "model_invocation.resolved"
    public static let signalReceived: SessionEventKind = "signal.received"
    public static let waitTimedOut: SessionEventKind = "wait.timed_out"
    public static let toolResultAppended: SessionEventKind = "tool_result.appended"
    public static let toolErrorAppended: SessionEventKind = "tool_error.appended"
    public static let sessionCompleted: SessionEventKind = "session.completed"
    public static let sessionFailed: SessionEventKind = "session.failed"
}

public struct SessionEvent: Codable, Sendable, Equatable, Hashable, Identifiable {
    public static let currentSchemaVersion = "native-agent.event/1"

    public let schemaVersion: String
    public let id: String
    public let sessionID: String
    public let kind: SessionEventKind
    public let createdAt: Date
    public let payload: JSONValue

    public init(
        schemaVersion: String = SessionEvent.currentSchemaVersion,
        id: String,
        sessionID: String,
        kind: SessionEventKind,
        createdAt: Date = DeterministicCoreDefaults.timestamp,
        payload: JSONValue = .object([:])
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.createdAt = createdAt
        self.payload = payload
    }

    public init(
        schemaVersion: String = SessionEvent.currentSchemaVersion,
        sessionID: String,
        kind: SessionEventKind,
        createdAt: Date = DeterministicCoreDefaults.timestamp,
        payload: JSONValue = .object([:])
    ) {
        self.init(
            schemaVersion: schemaVersion,
            id: DeterministicCoreDefaults.identifier(
                prefix: "event",
                components: [
                    schemaVersion,
                    sessionID,
                    kind.rawValue,
                    DeterministicCoreDefaults.dateComponent(createdAt),
                    payload.stableIdentityString()
                ]
            ),
            sessionID: sessionID,
            kind: kind,
            createdAt: createdAt,
            payload: payload
        )
    }

    package func validateState() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentError.persistenceFailure(
                "Unsupported durable session event schema version: \(schemaVersion)."
            )
        }
    }
}

public protocol SessionEventStore: Sendable {
    func loadEvents(sessionID: String) async throws -> [SessionEvent]
}
