import Foundation
import NativeAgentDomain

/// Deterministic state and validation policy for mutating tool-effect receipts.
/// Storage and time acquisition remain in `ToolEffectLedger`.
struct ToolEffectLedgerPolicy: Sendable {
  enum TerminalOutcome: Sendable {
    case completed(
      message: AgentMessage,
      artifacts: [ArtifactRecord],
      additionalMetadata: [String: JSONValue] = [:]
    )
    case failed(
      error: String,
      additionalMetadata: [String: JSONValue] = [:]
    )
  }

  private struct CompletionPayload: Codable, Sendable, Equatable {
    let message: AgentMessage
    let artifacts: [ArtifactRecord]
  }

  static func shouldTrack(_ definition: ToolDefinition) -> Bool {
    definition.effect != .readOnly
  }

  static func decision(
    record: EffectRecord?,
    call: ToolCall,
    definition: ToolDefinition,
    sessionID: String
  ) throws -> ToolEffectLedger.Decision {
    guard let record else { return .execute }
    try validate(record: record, call: call, definition: definition, sessionID: sessionID)

    switch record.status {
    case .completed:
      let payload = try completionPayload(from: record)
      return .replay(message: payload.message, artifacts: payload.artifacts)
    case .started:
      return .block(
        code: .unknownOutcome,
        message:
          "Mutating tool call \(call.id) is already started. Reapplication was blocked until its outcome is reconciled."
      )
    case .failed:
      return .block(
        code: .conflict,
        message:
          "Mutating tool call \(call.id) is already failed. Reapplication with the same operation identity was blocked."
      )
    }
  }

  static func makeStartedRecord(
    call: ToolCall,
    definition: ToolDefinition,
    sessionID: String,
    timestamp: Date
  ) throws -> EffectRecord {
    EffectRecord.started(
      sessionID: sessionID,
      scope: .toolCall,
      key: call.id,
      effectType: definition.name,
      createdAt: timestamp,
      updatedAt: timestamp,
      input: try JSONValue.encode(call),
      metadata: baseMetadata(definition: definition)
    )
  }

  static func makeTerminalRecord(
    from record: EffectRecord,
    call: ToolCall,
    definition: ToolDefinition,
    sessionID: String,
    outcome: TerminalOutcome,
    timestamp: Date
  ) throws -> EffectRecord {
    try validate(record: record, call: call, definition: definition, sessionID: sessionID)
    guard record.status != .completed else {
      throw AgentError.persistenceFailure(
        "Completed tool effect \(call.id) cannot transition to another terminal state."
      )
    }

    let updated: EffectRecord
    switch outcome {
    case .completed(let message, let artifacts, let additionalMetadata):
      let result = try JSONValue.encode(
        CompletionPayload(message: message, artifacts: artifacts)
      )
      updated = record.applying(
        .completed(
          effectType: definition.name,
          result: result,
          metadata: baseMetadata(
            definition: definition,
            additional: additionalMetadata
          ),
          updatedAt: timestamp
        )
      )

    case .failed(let error, let additionalMetadata):
      guard error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw AgentError.persistenceFailure(
          "Failed effect \(call.id) is missing an error."
        )
      }
      updated = record.applying(
        .failed(
          effectType: definition.name,
          error: error,
          metadata: baseMetadata(
            definition: definition,
            additional: additionalMetadata
          ),
          updatedAt: timestamp
        )
      )
    }

    try updated.validateState()
    return updated
  }

  static func validate(
    record: EffectRecord,
    call: ToolCall,
    definition: ToolDefinition,
    sessionID: String
  ) throws {
    try record.validateState()
    guard record.sessionID == sessionID,
      record.scope == .toolCall,
      record.key == call.id,
      record.effectType == definition.name
    else {
      throw AgentError.persistenceFailure("Effect ledger mismatch for tool call \(call.id).")
    }

    let decodedCall = try record.input.decode(ToolCall.self)
    guard decodedCall == call else {
      throw AgentError.persistenceFailure("Effect ledger input mismatch for tool call \(call.id).")
    }
  }

  private static func completionPayload(from record: EffectRecord) throws -> CompletionPayload {
    guard let result = record.result else {
      throw AgentError.persistenceFailure(
        "Missing completed tool effect payload for call \(record.key)."
      )
    }

    let payload = try result.decode(CompletionPayload.self)
    guard payload.message.role == .tool,
      payload.message.toolCallID == record.key,
      payload.message.toolName == record.effectType,
      payload.artifacts.allSatisfy({ $0.sessionID == record.sessionID })
    else {
      throw AgentError.persistenceFailure(
        "Invalid completed tool effect payload for call \(record.key)."
      )
    }
    return payload
  }

  private static func baseMetadata(
    definition: ToolDefinition,
    additional: [String: JSONValue] = [:]
  ) -> [String: JSONValue] {
    var metadata: [String: JSONValue] = [
      "capabilityID": .string(definition.capabilityID.rawValue),
      "effect": .string(definition.effect.rawValue),
      "approvalPolicy": .string(definition.approvalPolicy.rawValue),
    ]
    for (key, value) in additional {
      metadata[key] = value
    }
    return metadata
  }
}
