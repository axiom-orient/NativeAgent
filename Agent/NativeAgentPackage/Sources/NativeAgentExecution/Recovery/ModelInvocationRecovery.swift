import Foundation
import NativeAgentDomain

/// Durable identity of one model request whose external outcome may need host
/// reconciliation after process interruption.
public struct PendingModelInvocation: Codable, Sendable, Equatable {
  public let id: String
  public let sessionID: String
  public let providerID: String
  public let snapshotRevision: Int64
  public let request: ModelRequest
  public let createdAt: Date

  public init(
    id: String,
    sessionID: String,
    providerID: String,
    snapshotRevision: Int64,
    request: ModelRequest,
    createdAt: Date
  ) {
    self.id = id
    self.sessionID = sessionID
    self.providerID = providerID
    self.snapshotRevision = snapshotRevision
    self.request = request
    self.createdAt = createdAt
  }
}

/// Host-owned resolution for a model invocation whose remote outcome is unknown.
///
/// `retry` explicitly accepts the duplicate-request risk. NativeAgent never retries an
/// uncertain remote invocation without this decision.
public enum ModelInvocationRecoveryResolution: Sendable, Equatable {
  case completed(ModelTurn)
  case retry(reason: String)
  case failed(String)
}

/// Hash input only. Persisted requests use ModelInvocationManifest exclusively.
private struct ModelInvocationIdentity: Encodable, Sendable {
  let providerID: String
  let snapshotRevision: Int64
  let request: ModelRequest
}

private enum ModelInvocationMessageSource: String, Codable, Sendable, Equatable {
  case transcript
  case contextCheckpoint
  case inline
}

private struct ModelInvocationMessageEntry: Codable, Sendable, Equatable {
  let source: ModelInvocationMessageSource
  let messageID: String
  let contentSHA256: String
  let inlineMessage: AgentMessage?
}

private struct ModelInvocationDuration: Codable, Sendable, Equatable {
  let seconds: Int64
  let attoseconds: Int64

  init(_ duration: Duration) {
    let components = duration.components
    seconds = components.seconds
    attoseconds = components.attoseconds
  }

  var value: Duration {
    Duration(secondsComponent: seconds, attosecondsComponent: attoseconds)
  }
}

private struct ModelRequestScalars: Codable, Sendable, Equatable {
  let sessionID: String
  let modelID: String?
  let metadata: [String: JSONValue]
  let requiredCapabilities: ModelCapabilities
  let outputFormat: ModelOutputFormat
  let maxOutputBytes: Int
  let deadline: ModelInvocationDuration
  let limits: ModelGenerationLimits

  init(request: ModelRequest) {
    sessionID = request.sessionID
    modelID = request.modelID
    metadata = request.metadata
    requiredCapabilities = request.requiredCapabilities
    outputFormat = request.outputFormat
    maxOutputBytes = request.maxOutputBytes
    deadline = ModelInvocationDuration(request.deadline)
    limits = request.limits
  }

  func request(messages: [AgentMessage], tools: [ModelTool]) -> ModelRequest {
    ModelRequest(
      sessionID: sessionID,
      modelID: modelID,
      messages: messages,
      tools: tools,
      metadata: metadata,
      requiredCapabilities: requiredCapabilities,
      outputFormat: outputFormat,
      maxOutputBytes: maxOutputBytes,
      deadline: deadline.value,
      limits: limits
    )
  }
}

private struct ModelInvocationManifest: Codable, Sendable, Equatable {
  static let schemaVersion = "native-agent.model-invocation/2"

  let schemaVersion: String
  let providerID: String
  let snapshotRevision: Int64
  let request: ModelRequestScalars
  let messages: [ModelInvocationMessageEntry]
  let tools: [ModelTool]
  let semanticRequestSHA256: String
}

private struct ModelTurnReceipt: Codable, Sendable, Equatable {
  static let schemaVersion = "native-agent.model-turn/2"

  let schemaVersion: String
  let assistantMessageID: String
  let assistantMessageSHA256: String
  let providerMetadata: [String: JSONValue]
  let semanticTurnSHA256: String
}

enum ModelInvocationLedgerDecision: Sendable, Equatable {
  case invoke(PendingModelInvocation, startedRecord: EffectRecord)
  case replay(PendingModelInvocation, ModelTurn)
  case uncertain(PendingModelInvocation)
  case failed(PendingModelInvocation, String)
}

/// Durable model-call boundary.
///
/// The session transcript owns model-visible message bodies. The effect ledger owns only
/// invocation identity, references/digests, request-only projections, and effect state.
/// A `started` receipt is written before entering the provider adapter. The assistant turn
/// and `completed` receipt are committed together. If the process stops between those points,
/// the next run enters an explicit wait instead of issuing a blind duplicate request.
struct ModelInvocationLedger: Sendable {
  static let effectType = "model_invocation"

  let store: any SessionRuntimeStore
  let now: @Sendable () -> Date

  func decision(
    request: ModelRequest,
    snapshot: SessionSnapshot,
    snapshotRevision: Int64,
    providerID: String
  ) async throws -> ModelInvocationLedgerDecision {
    guard snapshot.sessionID == request.sessionID,
      snapshot.revision == snapshotRevision
    else {
      throw AgentError.effectLedgerFailure(
        "Model invocation source snapshot does not match request \(request.sessionID) revision \(snapshotRevision)."
      )
    }

    // Durable request identity is independent of the receipt envelope. A matching
    // unsupported receipt must be rejected before any provider can be invoked.
    let key = try Self.lookupKey(
      request: request,
      snapshotRevision: snapshotRevision,
      providerID: providerID
    )
    let createdAt = now()
    let pending = PendingModelInvocation(
      id: key,
      sessionID: request.sessionID,
      providerID: providerID,
      snapshotRevision: snapshotRevision,
      request: request,
      createdAt: createdAt
    )

    let record = try await load(
      sessionID: request.sessionID,
      key: key
    )
    guard let record else {
      let manifest = try Self.manifest(
        request: request,
        snapshot: snapshot,
        snapshotRevision: snapshotRevision,
        providerID: providerID
      )
      return .invoke(
        pending,
        startedRecord: EffectRecord.started(
          sessionID: request.sessionID,
          scope: .modelInvocation,
          key: key,
          effectType: Self.effectType,
          createdAt: createdAt,
          updatedAt: createdAt,
          input: try JSONValue.encode(manifest),
          metadata: [
            "providerID": .string(providerID),
            "snapshotRevision": .integer(snapshotRevision),
            "payloadSchema": .string(ModelInvocationManifest.schemaVersion),
          ]
        )
      )
    }

    let persisted = try Self.pending(from: record, snapshot: snapshot)
    guard persisted.providerID == providerID,
      persisted.snapshotRevision == snapshotRevision,
      persisted.request == request
    else {
      throw AgentError.effectLedgerFailure(
        "Model invocation record \(key) does not match the request being advanced."
      )
    }

    switch record.status {
    case .started:
      return .uncertain(persisted)
    case .completed:
      return .replay(persisted, try Self.completedTurn(from: record, snapshot: snapshot))
    case .failed:
      guard let error = record.error,
        error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      else {
        throw AgentError.effectLedgerFailure(
          "Failed model invocation \(key) is missing its error."
        )
      }
      return .failed(persisted, error)
    }
  }

  func pending(sessionID: String, key: String) async throws -> PendingModelInvocation {
    guard let record = try await load(sessionID: sessionID, key: key) else {
      throw AgentError.notFound(
        "No model invocation record exists for session \(sessionID), key \(key)."
      )
    }
    let snapshot = try await sourceSnapshot(sessionID: sessionID)
    return try Self.pending(from: record, snapshot: snapshot)
  }

  func record(sessionID: String, key: String) async throws -> EffectRecord {
    guard let record = try await load(sessionID: sessionID, key: key) else {
      throw AgentError.notFound(
        "No model invocation record exists for session \(sessionID), key \(key)."
      )
    }
    let snapshot = try await sourceSnapshot(sessionID: sessionID)
    _ = try Self.pending(from: record, snapshot: snapshot)
    return record
  }

  func save(_ record: EffectRecord) async throws {
    do {
      try await store.saveEffect(record)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AgentError.effectLedgerFailure(
        "Model invocation ledger write failed for session \(record.sessionID), "
          + "key \(record.key): \(error.localizedDescription)"
      )
    }
  }

  func completedRecord(
    startedRecord: EffectRecord,
    turn: ModelTurn,
    assistantMessage: AgentMessage
  ) throws -> EffectRecord {
    guard assistantMessage.role == .assistant,
      assistantMessage.contentParts == turn.contentParts,
      assistantMessage.toolCalls == turn.toolCalls,
      assistantMessage.usage == turn.usage,
      assistantMessage.responseID == turn.responseID,
      assistantMessage.reasoningSummary == turn.reasoningSummary,
      assistantMessage.stopReason == turn.stopReason
    else {
      throw AgentError.effectLedgerFailure(
        "Completed model invocation \(startedRecord.key) does not match its committed assistant message."
      )
    }

    let receipt = ModelTurnReceipt(
      schemaVersion: ModelTurnReceipt.schemaVersion,
      assistantMessageID: assistantMessage.id,
      assistantMessageSHA256: try Self.digest(assistantMessage),
      providerMetadata: turn.metadata,
      semanticTurnSHA256: try Self.semanticTurnDigest(turn)
    )
    return startedRecord.applying(
      .completed(
        effectType: Self.effectType,
        result: try JSONValue.encode(receipt),
        metadata: startedRecord.metadata,
        updatedAt: now()
      )
    )
  }

  func failedRecord(
    startedRecord: EffectRecord,
    error: String
  ) throws -> EffectRecord {
    let bounded = error.trimmingCharacters(in: .whitespacesAndNewlines)
    guard bounded.isEmpty == false else {
      throw AgentError.invariantViolation(
        "A failed model invocation must contain a non-empty error."
      )
    }
    return startedRecord.applying(
      .failed(
        effectType: Self.effectType,
        error: bounded,
        metadata: startedRecord.metadata,
        updatedAt: now()
      )
    )
  }

  private func load(sessionID: String, key: String) async throws -> EffectRecord? {
    do {
      return try await store.loadEffect(
        sessionID: sessionID,
        scope: .modelInvocation,
        key: key
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AgentError.effectLedgerFailure(
        "Model invocation ledger read failed for session \(sessionID), "
          + "key \(key): \(error.localizedDescription)"
      )
    }
  }

  private func sourceSnapshot(sessionID: String) async throws -> SessionSnapshot {
    do {
      guard let snapshot = try await store.loadSnapshot(sessionID: sessionID) else {
        throw AgentError.notFound("Session not found: \(sessionID)")
      }
      return snapshot
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AgentError {
      throw error
    } catch {
      throw AgentError.effectLedgerFailure(
        "Model invocation source snapshot read failed for session \(sessionID): \(error.localizedDescription)"
      )
    }
  }

  private static func manifest(
    request: ModelRequest,
    snapshot: SessionSnapshot,
    snapshotRevision: Int64,
    providerID: String
  ) throws -> ModelInvocationManifest {
    let entries = try request.messages.map { requestMessage in
      let transcriptMatches = snapshot.messages.filter { $0.id == requestMessage.id }
      guard transcriptMatches.count <= 1 else {
        throw AgentError.effectLedgerFailure(
          "Session \(snapshot.sessionID) contains duplicate message ID \(requestMessage.id)."
        )
      }
      if let durable = transcriptMatches.first, durable == requestMessage {
        return ModelInvocationMessageEntry(
          source: .transcript,
          messageID: durable.id,
          contentSHA256: try digest(durable),
          inlineMessage: nil
        )
      }
      if let durable = snapshot.contextCheckpoint?.summaryMessage,
        durable.id == requestMessage.id,
        durable == requestMessage
      {
        return ModelInvocationMessageEntry(
          source: .contextCheckpoint,
          messageID: durable.id,
          contentSHA256: try digest(durable),
          inlineMessage: nil
        )
      }
      return ModelInvocationMessageEntry(
        source: .inline,
        messageID: requestMessage.id,
        contentSHA256: try digest(requestMessage),
        inlineMessage: requestMessage
      )
    }

    return ModelInvocationManifest(
      schemaVersion: ModelInvocationManifest.schemaVersion,
      providerID: providerID,
      snapshotRevision: snapshotRevision,
      request: ModelRequestScalars(request: request),
      messages: entries,
      tools: request.tools,
      semanticRequestSHA256: try semanticRequestDigest(request)
    )
  }

  private static func pending(
    from record: EffectRecord,
    snapshot: SessionSnapshot
  ) throws -> PendingModelInvocation {
    guard record.scope == .modelInvocation,
      record.effectType == effectType
    else {
      throw AgentError.effectLedgerFailure(
        "Effect \(record.key) is not a model invocation record."
      )
    }
    try record.validateState()

    guard let schemaVersion = record.input.objectValue?["schemaVersion"]?.stringValue else {
      throw AgentError.effectLedgerFailure(
        "Model invocation \(record.key) is missing its payload schema."
      )
    }
    guard schemaVersion == ModelInvocationManifest.schemaVersion else {
      throw AgentError.effectLedgerFailure(
        "Model invocation \(record.key) uses unsupported payload schema \(schemaVersion)."
      )
    }
    let manifest: ModelInvocationManifest
    do {
      manifest = try record.input.decode(ModelInvocationManifest.self)
    } catch {
      throw AgentError.effectLedgerFailure(
        "Model invocation \(record.key) contains an invalid reference manifest: \(error.localizedDescription)"
      )
    }
    guard manifest.request.sessionID == record.sessionID else {
      throw AgentError.effectLedgerFailure(
        "Model invocation \(record.key) references the wrong session."
      )
    }
    let request = try hydrate(manifest: manifest, from: snapshot)
    let expectedKey = try lookupKey(
      request: request,
      snapshotRevision: manifest.snapshotRevision,
      providerID: manifest.providerID
    )
    guard record.key == expectedKey else {
      throw AgentError.effectLedgerFailure(
        "Model invocation \(record.key) has an invalid durable identity."
      )
    }
    return PendingModelInvocation(
      id: record.key,
      sessionID: record.sessionID,
      providerID: manifest.providerID,
      snapshotRevision: manifest.snapshotRevision,
      request: request,
      createdAt: record.createdAt
    )
  }

  private static func hydrate(
    manifest: ModelInvocationManifest,
    from snapshot: SessionSnapshot
  ) throws -> ModelRequest {
    guard snapshot.sessionID == manifest.request.sessionID else {
      throw AgentError.effectLedgerFailure(
        "Model invocation reference manifest does not belong to session \(snapshot.sessionID)."
      )
    }

    var transcriptByID: [String: AgentMessage] = [:]
    transcriptByID.reserveCapacity(snapshot.messages.count)
    for message in snapshot.messages {
      guard transcriptByID.updateValue(message, forKey: message.id) == nil else {
        throw AgentError.effectLedgerFailure(
          "Session \(snapshot.sessionID) contains duplicate message ID \(message.id)."
        )
      }
    }

    let messages = try manifest.messages.map { entry -> AgentMessage in
      let message: AgentMessage
      switch entry.source {
      case .transcript:
        guard entry.inlineMessage == nil,
          let durable = transcriptByID[entry.messageID]
        else {
          throw AgentError.effectLedgerFailure(
            "Model invocation message \(entry.messageID) cannot be hydrated from the transcript."
          )
        }
        message = durable
      case .contextCheckpoint:
        guard entry.inlineMessage == nil,
          let durable = snapshot.contextCheckpoint?.summaryMessage,
          durable.id == entry.messageID
        else {
          throw AgentError.effectLedgerFailure(
            "Model invocation message \(entry.messageID) cannot be hydrated from the context checkpoint."
          )
        }
        message = durable
      case .inline:
        guard let inline = entry.inlineMessage,
          inline.id == entry.messageID
        else {
          throw AgentError.effectLedgerFailure(
            "Model invocation inline message \(entry.messageID) is missing or has the wrong identity."
          )
        }
        message = inline
      }
      guard try digest(message) == entry.contentSHA256 else {
        throw AgentError.effectLedgerFailure(
          "Model invocation message \(entry.messageID) failed content verification."
        )
      }
      return message
    }

    let request = manifest.request.request(messages: messages, tools: manifest.tools)
    guard try semanticRequestDigest(request) == manifest.semanticRequestSHA256 else {
      throw AgentError.effectLedgerFailure(
        "Model invocation \(snapshot.sessionID) failed semantic request verification."
      )
    }
    return request
  }

  private static func completedTurn(
    from record: EffectRecord,
    snapshot: SessionSnapshot
  ) throws -> ModelTurn {
    guard let result = record.result else {
      throw AgentError.effectLedgerFailure(
        "Completed model invocation \(record.key) is missing its response."
      )
    }

    guard let schemaVersion = result.objectValue?["schemaVersion"]?.stringValue else {
      throw AgentError.effectLedgerFailure(
        "Completed model invocation \(record.key) is missing its result schema."
      )
    }
    guard schemaVersion == ModelTurnReceipt.schemaVersion else {
      throw AgentError.effectLedgerFailure(
        "Completed model invocation \(record.key) uses unsupported result schema \(schemaVersion)."
      )
    }
    let receipt: ModelTurnReceipt
    do {
      receipt = try result.decode(ModelTurnReceipt.self)
    } catch {
      throw AgentError.effectLedgerFailure(
        "Completed model invocation \(record.key) contains an invalid response receipt: \(error.localizedDescription)"
      )
    }
    let matches = snapshot.messages.filter { $0.id == receipt.assistantMessageID }
    guard matches.count == 1, let message = matches.first, message.role == .assistant else {
      throw AgentError.effectLedgerFailure(
        "Completed model invocation \(record.key) cannot hydrate assistant message \(receipt.assistantMessageID)."
      )
    }
    guard try digest(message) == receipt.assistantMessageSHA256 else {
      throw AgentError.effectLedgerFailure(
        "Completed model invocation \(record.key) assistant message failed content verification."
      )
    }
    let turn = ModelTurn(
      contentParts: message.contentParts,
      toolCalls: message.toolCalls,
      metadata: receipt.providerMetadata,
      usage: message.usage,
      responseID: message.responseID,
      reasoningSummary: message.reasoningSummary,
      stopReason: message.stopReason
    )
    guard try semanticTurnDigest(turn) == receipt.semanticTurnSHA256 else {
      throw AgentError.effectLedgerFailure(
        "Completed model invocation \(record.key) failed semantic response verification."
      )
    }
    return turn
  }

  private static func lookupKey(
    request: ModelRequest,
    snapshotRevision: Int64,
    providerID: String
  ) throws -> String {
    let input = ModelInvocationIdentity(
      providerID: providerID,
      snapshotRevision: snapshotRevision,
      request: request
    )
    let canonical = try JSONValue.encode(input).canonicalString()
    return "model-\(SHA256HexDigest.digest(canonical))"
  }

  private static func digest<T: Encodable>(_ value: T) throws -> String {
    SHA256HexDigest.digest(try JSONValue.encode(value).canonicalString())
  }

  static func semanticRequestDigest(_ request: ModelRequest) throws -> String {
    var components: [String] = [
      "request-v1",
      request.sessionID,
      request.modelID.map { "some:\($0)" } ?? "none",
      try JSONValue.object(request.metadata).canonicalString(),
      String(request.requiredCapabilities.rawValue),
      try outputFormatIdentity(request.outputFormat),
      String(request.maxOutputBytes),
      durationIdentity(request.deadline),
      limitsIdentity(request.limits),
    ]
    components.append(contentsOf: try request.messages.map(digest))
    components.append(contentsOf: try request.tools.map(digest))
    return SHA256HexDigest.digest(lengthPrefixed(components))
  }

  private static func semanticTurnDigest(_ turn: ModelTurn) throws -> String {
    SHA256HexDigest.digest(try JSONValue.encode(turn).canonicalString())
  }

  private static func outputFormatIdentity(_ format: ModelOutputFormat) throws -> String {
    switch format {
    case .text:
      return "text"
    case .jsonObject(let schema):
      return "json:\(try schema.canonicalString())"
    }
  }

  private static func durationIdentity(_ duration: Duration) -> String {
    let components = duration.components
    return "\(components.seconds):\(components.attoseconds)"
  }

  private static func limitsIdentity(_ limits: ModelGenerationLimits) -> String {
    [
      limits.version,
      String(limits.maxMessages),
      String(limits.maxMessageBytes),
      String(limits.maxInputBytes),
      String(limits.maxBinaryParts),
      String(limits.maxBinaryInputBytes),
      String(limits.maxBinaryOutputParts),
      String(limits.maxBinaryOutputBytes),
      String(limits.maxOutputBytes),
      String(limits.maxDeltaBytes),
      String(limits.maxFrameBytes),
      durationIdentity(limits.maxDeadline),
    ].joined(separator: ":")
  }

  private static func lengthPrefixed(_ components: [String]) -> String {
    components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  }
}

struct PendingModelInvocationResolver: Sendable {
  let store: any SessionRuntimeStore
  let now: @Sendable () -> Date

  func pending(from snapshot: SessionSnapshot) async throws -> PendingModelInvocation {
    guard snapshot.status == .waiting,
      let waitState = snapshot.waitState,
      waitState.kind == .modelInvocation
    else {
      throw AgentError.sessionWaiting(snapshot.sessionID)
    }
    let ledger = ModelInvocationLedger(store: store, now: now)
    let pending = try await ledger.pending(
      sessionID: snapshot.sessionID,
      key: waitState.identifier
    )
    guard waitState.details["providerID"]?.stringValue == pending.providerID,
      SessionCoordinator.waitStateSnapshotRevision(waitState) == pending.snapshotRevision
    else {
      throw AgentError.effectLedgerFailure(
        "Model invocation wait \(waitState.identifier) does not match its durable record."
      )
    }
    return pending
  }
}

package struct ModelInvocationRecoveryReconciliation: Sendable {
  package let snapshot: SessionSnapshot
  package let requiresContinuation: Bool
}

/// Provider-independent authority for recording the verified outcome of one uncertain model call.
/// It may leave the session runnable, but it never invokes a provider itself.
struct ModelInvocationRecoveryReconciler: Sendable {
  let store: any SessionRuntimeStore
  let registry: ToolRegistry
  let resourceValidator: RuntimeResourceValidator
  let configuration: RuntimeConfiguration
  let now: @Sendable () -> Date
  let idGenerator: @Sendable () -> String
  let snapshotWriter: RuntimeSnapshotWriter

  func reconcile(
    snapshot: SessionSnapshot,
    invocationID: String,
    resolution: ModelInvocationRecoveryResolution
  ) async throws -> ModelInvocationRecoveryReconciliation {
    let pending = try await PendingModelInvocationResolver(store: store, now: now).pending(
      from: snapshot)
    guard pending.id == invocationID else {
      throw AgentError.invariantViolation(
        "Model invocation resolution does not match the pending invocation."
      )
    }
    let ledger = ModelInvocationLedger(store: store, now: now)
    let record = try await ledger.record(sessionID: snapshot.sessionID, key: pending.id)
    guard record.status == .started else {
      throw AgentError.invariantViolation(
        "Model invocation \(pending.id) is \(record.status.rawValue), not uncertain."
      )
    }

    let transitions = AgentLoopSnapshotTransitions(
      now: now,
      idGenerator: idGenerator,
      maximumFailureMessageUTF8Bytes: configuration.resourceLimits.maxFailureMessageUTF8Bytes
    )

    switch resolution {
    case .completed(let turn):
      try resourceValidator.validate(turn: turn)
      let containsSensitiveToolCall = turn.toolCalls.contains { call in
        guard let definition = registry.definition(named: call.name) else {
          // Recovery must never downgrade an unknown historical tool call to non-sensitive.
          return true
        }
        return definition.containsSensitiveData
      }
      let continuation = ResponseContinuationController(
        policy: try ResponseContinuationMetadata.policy(from: snapshot.metadata)
      )
      let reduction = try transitions.recordingAssistantTurn(
        turn,
        containsSensitiveToolCall: containsSensitiveToolCall,
        continuation: continuation,
        in: snapshot
      )
      guard let assistantMessage = reduction.snapshot.messages.dropFirst(snapshot.messages.count).first else {
        throw AgentError.invariantViolation(
          "Model recovery did not append a durable assistant message."
        )
      }
      let completedEffect = try ledger.completedRecord(
        startedRecord: record,
        turn: turn,
        assistantMessage: assistantMessage
      )
      let assistantEntries = [SessionJournal.Entry.assistantTurn(assistantMessage)]
        + (reduction.snapshot.status == .completed ? [.sessionCompleted] : [])
      let resolved = try await snapshotWriter.persist(
        reduction,
        effects: [completedEffect],
        journalEntries: [
          .waitCleared(snapshot.waitState),
          .modelInvocationResolved(identifier: pending.id, outcome: "completed"),
        ] + assistantEntries
      )

      return ModelInvocationRecoveryReconciliation(
        snapshot: resolved,
        requiresContinuation: resolved.status == .running
      )

    case .retry(let rawReason):
      let reason = try boundedResolutionReason(rawReason)
      let failedEffect = try ledger.failedRecord(
        startedRecord: record,
        error: "Host authorized retry after uncertain outcome: \(reason)"
      )
      let reduction = try transitions.clearingWait(in: snapshot)
      return ModelInvocationRecoveryReconciliation(
        snapshot: try await snapshotWriter.persist(
          reduction,
          effects: [failedEffect],
          journalEntries: [
            .waitCleared(snapshot.waitState),
            .modelInvocationResolved(identifier: pending.id, outcome: "retry"),
          ]
        ),
        requiresContinuation: true
      )

    case .failed(let rawReason):
      let reason = try boundedResolutionReason(rawReason)
      let failureError = AgentError.modelFailure(reason)
      let failedEffect = try ledger.failedRecord(startedRecord: record, error: reason)
      let reduction = try transitions.markingFailed(snapshot, error: failureError)
      return ModelInvocationRecoveryReconciliation(
        snapshot: try await snapshotWriter.persist(
          reduction,
          effects: [failedEffect],
          journalEntries: [
            .modelInvocationResolved(identifier: pending.id, outcome: "failed"),
            .sessionFailed(errorType: String(reflecting: type(of: failureError))),
          ]
        ),
        requiresContinuation: false
      )
    }
  }

  private func boundedResolutionReason(_ rawReason: String) throws -> String {
    let reason = RuntimeSessionFailure.boundedMessage(
      rawReason,
      maximumUTF8Bytes: configuration.resourceLimits.maxFailureMessageUTF8Bytes
    ).message.trimmingCharacters(in: .whitespacesAndNewlines)
    try resourceValidator.validateFailureReason(reason)
    guard reason.isEmpty == false else {
      throw AgentError.invalidConfiguration(
        "Model invocation resolution reason must not be empty."
      )
    }
    return reason
  }
}

extension SessionCoordinator {
  /// Returns the durable model invocation awaiting host reconciliation.
  public func pendingModelInvocation(
    sessionID: String
  ) async throws -> PendingModelInvocation? {
    let snapshot = try await loadExistingSnapshot(sessionID: sessionID)
    guard snapshot.status == .waiting,
      snapshot.waitState?.kind == .modelInvocation
    else {
      return nil
    }
    return try await pendingModelInvocation(from: snapshot)
  }

  /// Records the verified outcome of one uncertain remote model call first, then only
  /// re-enters provider execution when the reconciled state actually requires continuation.
  @discardableResult
  public func resolvePendingModelInvocation(
    sessionID: String,
    invocationID: String,
    resolution: ModelInvocationRecoveryResolution
  ) async throws -> SessionSnapshot {
    try await withSessionExecution(sessionID: sessionID) {
      let snapshot = try await loadExistingSnapshotForAdvancement(sessionID: sessionID)
      let reconciliation = try await ModelInvocationRecoveryReconciler(
        store: store,
        registry: registry,
        resourceValidator: resourceValidator,
        configuration: configuration,
        now: now,
        idGenerator: idGenerator,
        snapshotWriter: snapshotWriter
      ).reconcile(
        snapshot: snapshot,
        invocationID: invocationID,
        resolution: resolution
      )
      guard reconciliation.requiresContinuation else {
        return reconciliation.snapshot
      }
      return try await advanceLoadedSnapshot(
        reconciliation.snapshot
      )
    }
  }

  private func pendingModelInvocation(
    from snapshot: SessionSnapshot
  ) async throws -> PendingModelInvocation {
    try await PendingModelInvocationResolver(store: store, now: now).pending(from: snapshot)
  }

  static func waitStateSnapshotRevision(_ waitState: SessionWaitState) -> Int64? {
    guard case .integer(let revision)? = waitState.details["snapshotRevision"] else {
      return nil
    }
    return revision
  }
}
