import Foundation
import LanguageModelCore

public struct SessionSnapshot: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = "native-agent.session/1"

  public private(set) var schemaVersion: String
  public private(set) var revision: Int64
  public private(set) var sessionID: String
  public private(set) var title: String?
  public private(set) var status: SessionStatus
  public private(set) var createdAt: Date
  public private(set) var updatedAt: Date
  public private(set) var messages: [AgentMessage]
  public private(set) var artifacts: [ArtifactRecord]
  public private(set) var providerID: String?
  public private(set) var modelID: String?
  public private(set) var metadata: [String: JSONValue]
  public private(set) var contextCheckpoint: SessionContextCheckpoint?
  public private(set) var waitState: SessionWaitState?
  public private(set) var failure: SessionFailure?
  public private(set) var lastSignal: SessionSignal?

  public init(
    schemaVersion: String = SessionSnapshot.currentSchemaVersion,
    revision: Int64 = 0,
    sessionID: String,
    title: String? = nil,
    status: SessionStatus = .running,
    createdAt: Date = DeterministicCoreDefaults.timestamp,
    updatedAt: Date = DeterministicCoreDefaults.timestamp,
    messages: [AgentMessage] = [],
    artifacts: [ArtifactRecord] = [],
    providerID: String? = nil,
    modelID: String? = nil,
    metadata: [String: JSONValue] = [:],
    contextCheckpoint: SessionContextCheckpoint? = nil,
    waitState: SessionWaitState? = nil,
    failure: SessionFailure? = nil,
    lastSignal: SessionSignal? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.sessionID = sessionID
    self.title = title
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messages = messages
    self.artifacts = artifacts
    self.providerID = providerID
    self.modelID = modelID
    self.metadata = metadata
    self.contextCheckpoint = contextCheckpoint
    precondition(
      Self.hasValidLifecycleShape(
        status: status,
        waitState: waitState,
        failure: failure
      ),
      "SessionSnapshot contains a status-incompatible wait or failure payload."
    )
    self.waitState = waitState
    self.failure = failure
    self.lastSignal = lastSignal
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case revision
    case sessionID
    case title
    case status
    case createdAt
    case updatedAt
    case messages
    case artifacts
    case providerID
    case modelID
    case metadata
    case contextCheckpoint
    case waitState
    case failure
    case lastSignal
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let status = try container.decode(SessionStatus.self, forKey: .status)
    let waitState = try container.decodeIfPresent(SessionWaitState.self, forKey: .waitState)
    let failure = try container.decodeIfPresent(SessionFailure.self, forKey: .failure)
    guard Self.hasValidLifecycleShape(status: status, waitState: waitState, failure: failure) else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "SessionSnapshot contains a status-incompatible wait or failure payload."
      )
    }

    self.schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
    self.revision = try container.decode(Int64.self, forKey: .revision)
    self.sessionID = try container.decode(String.self, forKey: .sessionID)
    self.title = try container.decodeIfPresent(String.self, forKey: .title)
    self.status = status
    self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    self.messages = try container.decode([AgentMessage].self, forKey: .messages)
    self.artifacts = try container.decode([ArtifactRecord].self, forKey: .artifacts)
    self.providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
    self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    self.metadata = try container.decode([String: JSONValue].self, forKey: .metadata)
    self.contextCheckpoint = try container.decodeIfPresent(
      SessionContextCheckpoint.self, forKey: .contextCheckpoint)
    self.waitState = waitState
    self.failure = failure
    self.lastSignal = try container.decodeIfPresent(SessionSignal.self, forKey: .lastSignal)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(revision, forKey: .revision)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encodeIfPresent(title, forKey: .title)
    try container.encode(status, forKey: .status)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(messages, forKey: .messages)
    try container.encode(artifacts, forKey: .artifacts)
    try container.encodeIfPresent(providerID, forKey: .providerID)
    try container.encodeIfPresent(modelID, forKey: .modelID)
    try container.encode(metadata, forKey: .metadata)
    try container.encodeIfPresent(contextCheckpoint, forKey: .contextCheckpoint)
    try container.encodeIfPresent(waitState, forKey: .waitState)
    try container.encodeIfPresent(failure, forKey: .failure)
    try container.encodeIfPresent(lastSignal, forKey: .lastSignal)
  }

  private static func hasValidLifecycleShape(
    status: SessionStatus,
    waitState: SessionWaitState?,
    failure: SessionFailure?
  ) -> Bool {
    switch status {
    case .waiting:
      return waitState != nil && failure == nil
    case .running, .completed:
      return waitState == nil && failure == nil
    case .failed:
      return waitState == nil
    }
  }

  package func validateState(checkpointPrefixValidation: Bool = true) throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw AgentError.persistenceFailure(
        "Unsupported durable session schema version: \(schemaVersion)."
      )
    }
    guard revision >= 0 else {
      throw AgentError.persistenceFailure(
        "Session \(sessionID) has a negative revision."
      )
    }

    switch (status, waitState) {
    case (.waiting, .some):
      break
    case (.waiting, .none):
      throw AgentError.persistenceFailure(
        "Session \(sessionID) is waiting without a wait state."
      )
    case (.running, .some), (.completed, .some), (.failed, .some):
      throw AgentError.persistenceFailure(
        "Session \(sessionID) has a wait state while status is \(status.rawValue)."
      )
    case (.running, .none), (.completed, .none), (.failed, .none):
      break
    }

    if status != .failed, failure != nil {
      throw AgentError.persistenceFailure(
        "Session \(sessionID) has failure details while status is \(status.rawValue)."
      )
    }

    if let lastSignal,
      lastSignal.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw AgentError.persistenceFailure(
        "Session \(sessionID) has an empty last signal identifier."
      )
    }

    if let contextCheckpoint {
      guard contextCheckpoint.preservedSystemMessageCount >= 0,
        contextCheckpoint.coveredMessageCount
          >= contextCheckpoint.preservedSystemMessageCount,
        contextCheckpoint.coveredMessageCount <= messages.count
      else {
        throw AgentError.persistenceFailure(
          "Session \(sessionID) has an invalid context checkpoint range."
        )
      }
      if checkpointPrefixValidation {
        let leadingSystemCount =
          messages.firstIndex(where: { $0.role != .system }) ?? messages.count
        guard contextCheckpoint.preservedSystemMessageCount <= leadingSystemCount else {
          throw AgentError.persistenceFailure(
            "Session \(sessionID) has an invalid context checkpoint prefix."
          )
        }
      }
      guard contextCheckpoint.summaryMessage.role == .assistant,
        contextCheckpoint.summaryMessage.toolCalls.isEmpty,
        contextCheckpoint.summaryMessage.toolCallID == nil,
        contextCheckpoint.summaryMessage.toolName == nil
      else {
        throw AgentError.persistenceFailure(
          "Session \(sessionID) has an invalid context checkpoint summary."
        )
      }
    }

    guard let waitState else { return }
    switch (waitState.kind, waitState.resumeAt) {
    case (.time, .some), (.approval, .none), (.modelInvocation, .none), (.signal, .none):
      break
    case (.time, .none):
      throw AgentError.persistenceFailure(
        "Session \(sessionID) has a time wait without resumeAt."
      )
    case (.approval, .some), (.modelInvocation, .some), (.signal, .some):
      throw AgentError.persistenceFailure(
        "Session \(sessionID) has resumeAt for a non-time wait."
      )
    }
  }

  package consuming func applying(_ event: SessionSnapshotEvent) -> SessionSnapshot {
    var result = self

    switch event {
    case .userPromptAppended(let message, let updatedAt):
      result.status = .running
      result.updatedAt = updatedAt
      result.messages.append(message)
      result.waitState = nil
      result.failure = nil
    case .appended(let messages, let artifacts, let updatedAt):
      result.updatedAt = updatedAt
      result.messages.append(contentsOf: messages)
      result.artifacts = artifacts
    case .resumedAndAppended(let messages, let artifacts, let updatedAt):
      result.status = .running
      result.updatedAt = updatedAt
      result.messages.append(contentsOf: messages)
      result.artifacts = artifacts
      result.waitState = nil
      result.failure = nil
    case .waitResolvedAndAppended(let messages, let artifacts, let updatedAt):
      result.status = .running
      result.updatedAt = updatedAt
      result.messages.append(contentsOf: messages)
      result.artifacts = artifacts
      result.waitState = nil
      result.failure = nil
    case .assistantTurnRecorded(let messages, let completesSession, let updatedAt):
      result.status = completesSession ? .completed : .running
      result.updatedAt = updatedAt
      result.messages.append(contentsOf: messages)
      result.waitState = nil
      result.failure = nil
    case .messagesReplaced(let messages, let updatedAt):
      result.updatedAt = updatedAt
      result.messages = messages
    case .metadataChanged(let metadata):
      result.metadata = metadata
      return result
    case .commandRecorded(let metadata, let updatedAt):
      result.metadata = metadata
      result.updatedAt = updatedAt
    case .contextCheckpointChanged(let checkpoint, let updatedAt):
      result.contextCheckpoint = checkpoint
      result.updatedAt = updatedAt
    case .resumed(let updatedAt):
      result.status = .running
      result.updatedAt = updatedAt
      result.waitState = nil
      result.failure = nil
    case .enteredWait(let waitState, let updatedAt):
      result.status = .waiting
      result.updatedAt = updatedAt
      result.waitState = waitState
      result.failure = nil
      result.lastSignal = nil
    case .clearedWait(let updatedAt):
      if result.status == .waiting {
        result.status = .running
      }
      result.updatedAt = updatedAt
      result.waitState = nil
      result.failure = nil
    case .signalReceived(let signal, let updatedAt):
      result.status = .running
      result.updatedAt = updatedAt
      result.waitState = nil
      result.failure = nil
      result.lastSignal = signal
    case .completed(let updatedAt):
      result.status = .completed
      result.updatedAt = updatedAt
      result.waitState = nil
      result.failure = nil
    case .failed(let failure, let updatedAt):
      result.status = .failed
      result.updatedAt = updatedAt
      result.waitState = nil
      result.failure = failure
    case .appendedAndFailed(let messages, let failure, let updatedAt):
      result.status = .failed
      result.updatedAt = updatedAt
      result.messages.append(contentsOf: messages)
      result.waitState = nil
      result.failure = failure
    }

    result.revision += 1
    return result
  }
}

package enum SessionSnapshotEvent: Sendable {
  case userPromptAppended(AgentMessage, updatedAt: Date)
  case appended(messages: [AgentMessage], artifacts: [ArtifactRecord], updatedAt: Date)
  case resumedAndAppended(
    messages: [AgentMessage],
    artifacts: [ArtifactRecord],
    updatedAt: Date
  )
  case waitResolvedAndAppended(
    messages: [AgentMessage],
    artifacts: [ArtifactRecord],
    updatedAt: Date
  )
  case assistantTurnRecorded(
    messages: [AgentMessage],
    completesSession: Bool,
    updatedAt: Date
  )
  case messagesReplaced([AgentMessage], updatedAt: Date)
  case metadataChanged([String: JSONValue])
  case commandRecorded([String: JSONValue], updatedAt: Date)
  case contextCheckpointChanged(SessionContextCheckpoint, updatedAt: Date)
  case resumed(updatedAt: Date)
  case enteredWait(SessionWaitState, updatedAt: Date)
  case clearedWait(updatedAt: Date)
  case signalReceived(SessionSignal, updatedAt: Date)
  case completed(updatedAt: Date)
  case failed(SessionFailure, updatedAt: Date)
  case appendedAndFailed(
    messages: [AgentMessage],
    failure: SessionFailure,
    updatedAt: Date
  )
}
