import NativeAgentDomain
import LanguageModelCore

/// Separates durable managed-session identity from per-request response options.
/// Reserved identity keys are rejected, never silently overwritten.
struct ManagedRunMetadata: Sendable {
  let session: [String: JSONValue]
  let request: [String: JSONValue]

  init(
    caller: [String: JSONValue],
    agentID: String,
    soulDigest: String,
    skillDigest: String,
    responseDigest: String
  ) throws {
    var session = try Self.validateCaller(caller)
    if let options = session.removeValue(forKey: AgentResponseOptions.metadataKey) {
      self.request = [AgentResponseOptions.metadataKey: options]
    } else {
      self.request = [:]
    }
    session[AgentManager.agentMetadataKey] = .string(agentID)
    session[AgentManager.soulSnapshotMetadataKey] = .string(soulDigest)
    session[AgentManager.skillSnapshotMetadataKey] = .string(skillDigest)
    session[AgentManager.responseSnapshotMetadataKey] = .string(responseDigest)
    self.session = session
  }

  /// One validation owner for run/send/queue/edit/fork/wait-resume metadata.
  static func validateCaller(_ metadata: [String: JSONValue]) throws -> [String: JSONValue] {
    guard metadata[AgentManager.agentMetadataKey] == nil,
      metadata[AgentManager.soulSnapshotMetadataKey] == nil,
      metadata[AgentManager.skillSnapshotMetadataKey] == nil,
      metadata[AgentManager.responseSnapshotMetadataKey] == nil
    else {
      throw AgentError.invalidConfiguration("Managed Agent metadata keys are reserved.")
    }
    return metadata
  }

}
