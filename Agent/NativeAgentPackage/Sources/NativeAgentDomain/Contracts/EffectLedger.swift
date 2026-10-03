import Foundation
import LanguageModelCore

public struct EffectScope: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: StringLiteralType) {
    self.init(rawValue: value)
  }

  public static let toolCall: EffectScope = "tool_call"
  public static let approval: EffectScope = "approval"
  public static let modelInvocation: EffectScope = "model_invocation"
}

public enum EffectStatus: String, Codable, Sendable, Equatable {
  case started
  case completed
  case failed
}

public struct EffectRecord: Codable, Sendable, Equatable {
  public let sessionID: String
  public let scope: EffectScope
  public let key: String
  public let effectType: String
  public let status: EffectStatus
  public let createdAt: Date
  public let updatedAt: Date
  public let input: JSONValue
  public let result: JSONValue?
  public let error: String?
  public let metadata: [String: JSONValue]

  public init(
    sessionID: String,
    scope: EffectScope,
    key: String,
    effectType: String,
    status: EffectStatus,
    createdAt: Date = DeterministicCoreDefaults.timestamp,
    updatedAt: Date = DeterministicCoreDefaults.timestamp,
    input: JSONValue = .null,
    result: JSONValue? = nil,
    error: String? = nil,
    metadata: [String: JSONValue] = [:]
  ) {
    self.sessionID = sessionID
    self.scope = scope
    self.key = key
    self.effectType = effectType
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.input = input
    self.result = result
    self.error = error
    self.metadata = metadata
  }

  package static func started(
    sessionID: String,
    scope: EffectScope,
    key: String,
    effectType: String,
    createdAt: Date,
    updatedAt: Date,
    input: JSONValue,
    metadata: [String: JSONValue] = [:]
  ) -> EffectRecord {
    EffectRecord(
      sessionID: sessionID,
      scope: scope,
      key: key,
      effectType: effectType,
      status: .started,
      createdAt: createdAt,
      updatedAt: updatedAt,
      input: input,
      result: nil,
      error: nil,
      metadata: metadata
    )
  }

  package static func completed(
    sessionID: String,
    scope: EffectScope,
    key: String,
    effectType: String,
    createdAt: Date,
    updatedAt: Date,
    input: JSONValue,
    result: JSONValue,
    metadata: [String: JSONValue] = [:]
  ) -> EffectRecord {
    EffectRecord(
      sessionID: sessionID,
      scope: scope,
      key: key,
      effectType: effectType,
      status: .completed,
      createdAt: createdAt,
      updatedAt: updatedAt,
      input: input,
      result: result,
      error: nil,
      metadata: metadata
    )
  }

  package static func failed(
    sessionID: String,
    scope: EffectScope,
    key: String,
    effectType: String,
    createdAt: Date,
    updatedAt: Date,
    input: JSONValue,
    error: String,
    metadata: [String: JSONValue] = [:]
  ) -> EffectRecord {
    EffectRecord(
      sessionID: sessionID,
      scope: scope,
      key: key,
      effectType: effectType,
      status: .failed,
      createdAt: createdAt,
      updatedAt: updatedAt,
      input: input,
      result: nil,
      error: error,
      metadata: metadata
    )
  }

  package func validateState() throws {
    let hasError = error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    switch scope {
    case .toolCall, .modelInvocation:
      switch status {
      case .started:
        guard result == nil, hasError == false else {
          throw AgentError.persistenceFailure(
            "Started tool effect \(key) contains a terminal payload."
          )
        }
      case .completed:
        guard result != nil, hasError == false else {
          throw AgentError.persistenceFailure(
            "Completed tool effect \(key) has an invalid result/error state."
          )
        }
      case .failed:
        guard result == nil, hasError else {
          throw AgentError.persistenceFailure(
            "Failed tool effect \(key) has an invalid result/error state."
          )
        }
      }
    case .approval:
      guard status == .completed, result != nil, hasError == false else {
        throw AgentError.persistenceFailure(
          "Approval effect \(key) must contain one completed decision."
        )
      }
    default:
      break
    }
  }

  /// Validates one durable replacement against the currently persisted receipt.
  ///
  /// Receipt identity is immutable. `completed` is final, while a host may
  /// reconcile an uncertain `failed` receipt to either a more precise failure
  /// or a verified completion. The storage boundary calls this inside the
  /// same transaction as the upsert so stale writers cannot reduce certainty.
  package func validateReplacement(of existing: EffectRecord) throws {
    try existing.validateState()
    try validateState()

    guard sessionID == existing.sessionID,
      scope == existing.scope,
      key == existing.key,
      effectType == existing.effectType,
      createdAt == existing.createdAt,
      input == existing.input
    else {
      throw AgentError.persistenceFailure(
        "Effect receipt identity cannot change for \(scope.rawValue)/\(key)."
      )
    }
    guard updatedAt >= existing.updatedAt else {
      throw AgentError.persistenceFailure(
        "Effect receipt \(scope.rawValue)/\(key) has a stale update timestamp."
      )
    }
    guard self != existing else { return }

    switch existing.status {
    case .completed:
      throw AgentError.persistenceFailure(
        "Completed effect receipt \(scope.rawValue)/\(key) is immutable."
      )
    case .started:
      guard status == .completed || status == .failed else {
        throw AgentError.persistenceFailure(
          "Started effect receipt \(scope.rawValue)/\(key) cannot be rewritten as started."
        )
      }
    case .failed:
      guard status == .failed || status == .completed else {
        throw AgentError.persistenceFailure(
          "Failed effect receipt \(scope.rawValue)/\(key) cannot return to started."
        )
      }
    }
  }

  package func applying(_ event: EffectRecordEvent) -> EffectRecord {
    switch event {
    case .completed(let effectType, let result, let metadata, let updatedAt):
      return .completed(
        sessionID: sessionID,
        scope: scope,
        key: key,
        effectType: effectType,
        createdAt: createdAt,
        updatedAt: updatedAt,
        input: input,
        result: result,
        metadata: metadata
      )
    case .failed(let effectType, let error, let metadata, let updatedAt):
      return .failed(
        sessionID: sessionID,
        scope: scope,
        key: key,
        effectType: effectType,
        createdAt: createdAt,
        updatedAt: updatedAt,
        input: input,
        error: error,
        metadata: metadata
      )
    }
  }
}

package enum EffectRecordEvent: Sendable {
  case completed(
    effectType: String, result: JSONValue, metadata: [String: JSONValue], updatedAt: Date)
  case failed(effectType: String, error: String, metadata: [String: JSONValue], updatedAt: Date)
}

public protocol EffectLedgerStore: Sendable {
  func loadEffect(sessionID: String, scope: EffectScope, key: String) async throws -> EffectRecord?
  func saveEffect(_ effect: EffectRecord) async throws
}
