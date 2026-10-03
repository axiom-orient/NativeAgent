import Foundation
import LanguageModelCore

public enum SessionWaitKind: String, Codable, Sendable, Equatable {
  case approval
  case modelInvocation = "model_invocation"
  case signal
  case time
}

public struct SessionWaitState: Codable, Sendable, Equatable {
  public let kind: SessionWaitKind
  public let identifier: String
  public let createdAt: Date
  public let resumeAt: Date?
  public let details: [String: JSONValue]

  public init(
    kind: SessionWaitKind,
    identifier: String,
    createdAt: Date = DeterministicCoreDefaults.timestamp,
    resumeAt: Date? = nil,
    details: [String: JSONValue] = [:]
  ) {
    precondition(
      Self.hasValidResumeShape(kind: kind, resumeAt: resumeAt),
      "SessionWaitState resumeAt does not match its kind."
    )
    self.kind = kind
    self.identifier = identifier
    self.createdAt = createdAt
    self.resumeAt = resumeAt
    self.details = details
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case identifier
    case createdAt
    case resumeAt
    case details
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(SessionWaitKind.self, forKey: .kind)
    let identifier = try container.decode(String.self, forKey: .identifier)
    let createdAt = try container.decode(Date.self, forKey: .createdAt)
    let resumeAt = try container.decodeIfPresent(Date.self, forKey: .resumeAt)
    let details = try container.decode([String: JSONValue].self, forKey: .details)

    guard Self.hasValidResumeShape(kind: kind, resumeAt: resumeAt) else {
      throw DecodingError.dataCorruptedError(
        forKey: .resumeAt,
        in: container,
        debugDescription: "SessionWaitState resumeAt does not match its kind."
      )
    }

    self.kind = kind
    self.identifier = identifier
    self.createdAt = createdAt
    self.resumeAt = resumeAt
    self.details = details
  }

  private static func hasValidResumeShape(kind: SessionWaitKind, resumeAt: Date?) -> Bool {
    switch (kind, resumeAt) {
    case (.time, .some), (.approval, .none), (.modelInvocation, .none), (.signal, .none):
      return true
    case (.time, .none), (.approval, .some), (.modelInvocation, .some), (.signal, .some):
      return false
    }
  }

  public static func approval(
    request: ApprovalRequest,
    createdAt: Date = DeterministicCoreDefaults.timestamp
  ) -> SessionWaitState {
    SessionWaitState(
      kind: .approval,
      identifier: request.id,
      createdAt: createdAt,
      details: [
        "toolCallID": .string(request.toolCall.id),
        "toolName": .string(request.toolCall.name),
        "capabilityID": .string(request.definition.capabilityID.rawValue),
      ]
    )
  }

  public static func modelInvocation(
    identifier: String,
    providerID: String,
    snapshotRevision: Int64,
    createdAt: Date = DeterministicCoreDefaults.timestamp
  ) -> SessionWaitState {
    SessionWaitState(
      kind: .modelInvocation,
      identifier: identifier,
      createdAt: createdAt,
      details: [
        "providerID": .string(providerID),
        "snapshotRevision": .integer(snapshotRevision),
      ]
    )
  }

  public static func signal(
    identifier: String,
    createdAt: Date = DeterministicCoreDefaults.timestamp,
    details: [String: JSONValue] = [:]
  ) -> SessionWaitState {
    SessionWaitState(
      kind: .signal,
      identifier: identifier,
      createdAt: createdAt,
      details: details
    )
  }

  public static func time(
    identifier: String,
    resumeAt: Date,
    createdAt: Date = DeterministicCoreDefaults.timestamp,
    details: [String: JSONValue] = [:]
  ) -> SessionWaitState {
    SessionWaitState(
      kind: .time,
      identifier: identifier,
      createdAt: createdAt,
      resumeAt: resumeAt,
      details: details
    )
  }
}
