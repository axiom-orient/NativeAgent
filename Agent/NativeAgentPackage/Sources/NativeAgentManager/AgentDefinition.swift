import Foundation
import LanguageModelRuntime

/// Selects the single authority for durable factual knowledge used by a managed Agent.
///
/// This policy is intentionally provider- and knowledge-system-neutral. An external
/// knowledge base may be ASK or any other host-owned authority; NativeAgent only needs
/// to know whether its own curated `MEMORY.md` writer is allowed to exist.
public enum AgentKnowledgeOwnership: String, Codable, Hashable, Sendable {
  case localCuratedMemory
  case externalKnowledgeBase
}

/// Persistent identity and explicit provider choice for one managed Agent.
/// Soul and user context remain inspectable documents next to this file. Curated
/// `MEMORY.md` exists only when `knowledgeOwnership == .localCuratedMemory`.
public struct AgentDefinition: Codable, Hashable, Sendable, Identifiable {
  public static let currentSchemaVersion = "native-agent.agent/1"

  public let schemaVersion: String
  public let id: String
  public let name: String
  public let provider: ModelProviderSelection
  public let knowledgeOwnership: AgentKnowledgeOwnership
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    schemaVersion: String = AgentDefinition.currentSchemaVersion,
    id: String,
    name: String,
    provider: ModelProviderSelection,
    knowledgeOwnership: AgentKnowledgeOwnership = .localCuratedMemory,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) throws {
    try AgentIdentity.validate(id: id)
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard schemaVersion == Self.currentSchemaVersion,
      !normalizedName.isEmpty,
      normalizedName.utf8.count <= 256,
      createdAt.timeIntervalSince1970.isFinite,
      updatedAt.timeIntervalSince1970.isFinite,
      updatedAt >= createdAt
    else {
      throw ManagedAgentError.invalidDefinition
    }
    self.schemaVersion = schemaVersion
    self.id = id
    self.name = normalizedName
    self.provider = try ModelProviderSelection(
      providerID: provider.providerID,
      modelID: provider.modelID
    )
    self.knowledgeOwnership = knowledgeOwnership
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, id, name, provider, knowledgeOwnership, createdAt, updatedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: container.decode(String.self, forKey: .schemaVersion),
      id: container.decode(String.self, forKey: .id),
      name: container.decode(String.self, forKey: .name),
      provider: container.decode(ModelProviderSelection.self, forKey: .provider),
      knowledgeOwnership: container.decode(
        AgentKnowledgeOwnership.self,
        forKey: .knowledgeOwnership
      ),
      createdAt: container.decode(Date.self, forKey: .createdAt),
      updatedAt: container.decode(Date.self, forKey: .updatedAt)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(provider, forKey: .provider)
    try container.encode(knowledgeOwnership, forKey: .knowledgeOwnership)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  public func selectingProvider(
    _ provider: ModelProviderSelection,
    updatedAt: Date = Date()
  ) throws -> AgentDefinition {
    try AgentDefinition(
      schemaVersion: schemaVersion,
      id: id,
      name: name,
      provider: provider,
      knowledgeOwnership: knowledgeOwnership,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

public enum ManagedAgentError: Error, Equatable, Sendable, LocalizedError {
  case invalidAgentID
  case invalidDefinition
  case alreadyExists(String)
  case notFound(String)
  case emptySoul
  case documentTooLarge(String)
  case localMemoryDisabled
  case sessionOwnedByDifferentAgent
  case sessionMissingProviderIdentity
  case soulSnapshotChanged
  case skillSnapshotChanged
  case selectedProviderCannotUseSkills(String)
  case unpinnedRemoteSkill(String)
  case invalidSkillSnapshot

  public var errorDescription: String? {
    switch self {
    case .invalidAgentID:
      return
        "Agent identifier must be 1...64 ASCII lowercase letters, numbers, dots, underscores, or hyphens and must not contain '..'."
    case .invalidDefinition:
      return "Managed Agent definition is invalid."
    case .alreadyExists(let id):
      return "Managed Agent already exists: \(id)"
    case .notFound(let id):
      return "Managed Agent not found: \(id)"
    case .emptySoul:
      return "SOUL.md must contain non-empty Agent identity and behavioral instructions."
    case .documentTooLarge(let name):
      return "Managed Agent document exceeds its bounded size: \(name)"
    case .localMemoryDisabled:
      return "Local curated memory is disabled because factual knowledge is externally owned."
    case .sessionOwnedByDifferentAgent:
      return "The durable session belongs to a different managed Agent."
    case .sessionMissingProviderIdentity:
      return "The durable session does not contain a pinned provider/model identity."
    case .soulSnapshotChanged:
      return "The Agent Soul changed. Start a new session to adopt the new Agent identity revision."
    case .skillSnapshotChanged:
      return
        "The selected skill execution snapshot changed. Start a new session to adopt the new skill revision."
    case .selectedProviderCannotUseSkills(let providerID):
      return
        "Provider \(providerID) cannot execute the selected Agent skills because its adapter does not support tool calls."
    case .unpinnedRemoteSkill(let name):
      return
        "Selected remote skill \(name) is not materialized locally. Install/import it before starting a managed session so its execution revision can be pinned."
    case .invalidSkillSnapshot:
      return "The selected skill workspace cannot be converted into a stable execution snapshot."
    }
  }
}

enum AgentIdentity {
  static func validate(id: String) throws {
    let bytes = Array(id.utf8)
    guard (1...64).contains(bytes.count), !id.contains(".."),
      bytes.allSatisfy({ byte in
        switch byte {
        case 45, 46, 48...57, 95, 97...122: true
        default: false
        }
      }),
      !id.hasPrefix("."), !id.hasSuffix(".")
    else {
      throw ManagedAgentError.invalidAgentID
    }
  }
}
