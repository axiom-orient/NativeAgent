import Foundation
import NativeAgentDomain

/// Durable approval-decision boundary.
///
/// Approval is a causal input to tool execution. It must survive process restart
/// and must be validated against the exact session, tool call, and definition
/// before it can authorize an effect.
struct ApprovalEffectLedger: Sendable {
  static let effectType = "tool_approval"

  let store: (any EffectLedgerStore)?
  let now: @Sendable () -> Date

  func decision(
    for call: ToolCall,
    definition: ToolDefinition,
    sessionID: String
  ) async throws -> ApprovalDecision? {
    guard let store else { return nil }

    let record: EffectRecord?
    do {
      record = try await store.loadEffect(
        sessionID: sessionID,
        scope: .approval,
        key: call.id
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AgentError.effectLedgerFailure(
        "Approval ledger read failed for session \(sessionID), tool call \(call.id): "
          + error.localizedDescription
      )
    }

    guard let record else { return nil }
    return try Self.decodeDecision(
      from: record,
      call: call,
      definition: definition,
      sessionID: sessionID
    )
  }

  func completedRecord(
    request: ApprovalRequest,
    decision: ApprovalDecision
  ) throws -> EffectRecord? {
    guard store != nil else { return nil }
    return EffectRecord.completed(
      sessionID: request.sessionID,
      scope: .approval,
      key: request.toolCall.id,
      effectType: Self.effectType,
      createdAt: request.createdAt,
      updatedAt: now(),
      input: try JSONValue.encode(request),
      result: try JSONValue.encode(decision),
      metadata: [
        "requestID": .string(request.id),
        "toolName": .string(request.toolCall.name),
        "capabilityID": .string(request.definition.capabilityID.rawValue),
      ]
    )
  }

  private static func decodeDecision(
    from record: EffectRecord,
    call: ToolCall,
    definition: ToolDefinition,
    sessionID: String
  ) throws -> ApprovalDecision {
    guard record.sessionID == sessionID,
      record.scope == .approval,
      record.key == call.id,
      record.effectType == effectType,
      record.status == .completed,
      record.error == nil,
      record.result != nil
    else {
      throw AgentError.effectLedgerFailure(
        "Approval record for session \(sessionID), tool call \(call.id) has an invalid state."
      )
    }

    let storedRequest: ApprovalRequest
    let storedDecision: ApprovalDecision
    do {
      storedRequest = try record.input.decode(ApprovalRequest.self)
      storedDecision = try record.result!.decode(ApprovalDecision.self)
    } catch {
      throw AgentError.effectLedgerFailure(
        "Approval record for session \(sessionID), tool call \(call.id) is not decodable: "
          + error.localizedDescription
      )
    }

    guard storedRequest.sessionID == sessionID,
      storedRequest.toolCall == call,
      storedRequest.definition == definition
    else {
      throw AgentError.effectLedgerFailure(
        "Approval record for session \(sessionID), tool call \(call.id) does not match the pending invocation."
      )
    }
    return storedDecision
  }
}
