import Foundation
import NativeAgent
import LanguageModelCore
import LanguageModelRuntime
import NativeAgentSkills

struct AgentPromptSnapshot: Sendable {
  let systemPrompt: String
  let soulDigest: String
}

/// File-first per-Agent workspace under the one `AgentDataStore` root.
///
/// Canonical semantic state is deliberately small:
/// - `SOUL.md`: identity, behavioral invariants and priorities.
/// - `USER.md`: stable user preferences/directives.
/// - `MEMORY.md`: optional curated durable facts/decisions, only for local ownership.
/// - `skills/`: Agent Skills packages and their local state.
///
/// Durable session transcripts/effects remain in `AgentDataStore.storage`; credentials stay in
/// provider/Keychain authority rather than being copied into this workspace.
actor AgentWorkspace {
  static let maximumSoulBytes = 8 * 1_024
  static let maximumUserBytes = 6 * 1_024
  static let maximumMemoryBytes = 12 * 1_024

  let dataStore: AgentDataStore
  private let fileManager: FileManager

  init(dataStore: AgentDataStore, fileManager: FileManager = .default) {
    self.dataStore = dataStore
    self.fileManager = fileManager
  }

  func definitions() throws -> [AgentDefinition] {
    let root = agentsRootURL
    guard fileManager.fileExists(atPath: root.path) else { return [] }
    let entries = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    var definitions: [AgentDefinition] = []
    for entry in entries where !entry.lastPathComponent.hasPrefix(".creating-") {
      guard try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        continue
      }
      definitions.append(try loadDefinition(id: entry.lastPathComponent))
    }
    return definitions.sorted { $0.id < $1.id }
  }

  func create(
    id: String,
    name: String,
    provider: ModelProviderSelection,
    soul: String,
    user: String = "",
    memory: String = "",
    knowledgeOwnership: AgentKnowledgeOwnership = .localCuratedMemory,
    response: AgentResponseConfiguration = .standard,
    now: Date = Date()
  ) throws -> AgentDefinition {
    try AgentIdentity.validate(id: id)
    try response.validate()
    try validateDocument(
      soul, name: "SOUL.md", maximumBytes: Self.maximumSoulBytes, allowEmpty: false)
    try validateDocument(
      user, name: "USER.md", maximumBytes: Self.maximumUserBytes, allowEmpty: true)
    switch knowledgeOwnership {
    case .localCuratedMemory:
      try validateDocument(
        memory, name: "MEMORY.md", maximumBytes: Self.maximumMemoryBytes, allowEmpty: true)
    case .externalKnowledgeBase:
      guard memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ManagedAgentError.localMemoryDisabled
      }
    }

    return try mutationFence.withExclusiveMutation("agent.create") {
      let finalURL = agentRootURL(id: id)
      guard !fileManager.fileExists(atPath: finalURL.path) else {
        throw ManagedAgentError.alreadyExists(id)
      }
      let staging = agentsRootURL.appendingPathComponent(
        ".creating-\(UUID().uuidString)", isDirectory: true)
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

      do {
        let definition = try AgentDefinition(
          id: id,
          name: name,
          provider: provider,
          knowledgeOwnership: knowledgeOwnership,
          createdAt: now,
          updatedAt: now
        )
        try writeJSON(definition, to: staging.appendingPathComponent("agent.json"))
        try writeText(soul, to: staging.appendingPathComponent("SOUL.md"))
        try writeText(user, to: staging.appendingPathComponent("USER.md"))
        if knowledgeOwnership == .localCuratedMemory {
          try writeText(memory, to: staging.appendingPathComponent("MEMORY.md"))
        }
        try writeJSON(response, to: staging.appendingPathComponent("RESPONSE.json"))
        try fileManager.createDirectory(
          at: staging.appendingPathComponent("skills", isDirectory: true),
          withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: staging, to: finalURL)
        return definition
      } catch {
        let creationError = error
        if fileManager.fileExists(atPath: staging.path) {
          do {
            try fileManager.removeItem(at: staging)
          } catch {
            throw AgentError.persistenceFailure(
              "Agent creation failed: \(creationError); staging cleanup failed: \(error)"
            )
          }
        }
        throw creationError
      }
    }
  }

  func definition(id: String) throws -> AgentDefinition {
    try loadDefinition(id: id)
  }

  func selectProvider(
    agentID: String,
    provider: ModelProviderSelection,
    now: Date = Date()
  ) throws -> AgentDefinition {
    try mutationFence.withExclusiveMutation("agent.selectProvider") {
      let current = try loadDefinition(id: agentID)
      let next = try current.selectingProvider(provider, updatedAt: now)
      try writeJSON(next, to: profileURL(id: agentID), atomic: true)
      return next
    }
  }

  func soul(agentID: String) throws -> String {
    try readText(soulURL(id: agentID), required: true)
  }

  func user(agentID: String) throws -> String {
    try readText(userURL(id: agentID), required: false)
  }

  func memory(agentID: String) throws -> String {
    let definition = try loadDefinition(id: agentID)
    guard definition.knowledgeOwnership == .localCuratedMemory else {
      throw ManagedAgentError.localMemoryDisabled
    }
    return try readText(memoryURL(id: agentID), required: false)
  }

  func setSoul(agentID: String, _ value: String) throws {
    try validateDocument(
      value, name: "SOUL.md", maximumBytes: Self.maximumSoulBytes, allowEmpty: false)
    try mutationFence.withExclusiveMutation("agent.setSoul") {
      _ = try loadDefinition(id: agentID)
      try writeText(value, to: soulURL(id: agentID), atomic: true)
    }
  }

  func setUser(agentID: String, _ value: String) throws {
    try validateDocument(
      value, name: "USER.md", maximumBytes: Self.maximumUserBytes, allowEmpty: true)
    try mutationFence.withExclusiveMutation("agent.setUser") {
      _ = try loadDefinition(id: agentID)
      try writeText(value, to: userURL(id: agentID), atomic: true)
    }
  }

  func setMemory(agentID: String, _ value: String) throws {
    try validateDocument(
      value, name: "MEMORY.md", maximumBytes: Self.maximumMemoryBytes, allowEmpty: true)
    try mutationFence.withExclusiveMutation("agent.setMemory") {
      let definition = try loadDefinition(id: agentID)
      guard definition.knowledgeOwnership == .localCuratedMemory else {
        throw ManagedAgentError.localMemoryDisabled
      }
      try writeText(value, to: memoryURL(id: agentID), atomic: true)
    }
  }

  func responseConfiguration(agentID: String) throws -> AgentResponseConfiguration {
    _ = try loadDefinition(id: agentID)
    let url = agentRootURL(id: agentID).appendingPathComponent("RESPONSE.json")
    let handle = try FileHandle(forReadingFrom: url)
    var closeAttempted = false
    do {
      let data = try handle.read(upToCount: 16 * 1_024 + 1) ?? Data()
      guard data.count <= 16 * 1_024 else {
        throw ManagedAgentError.documentTooLarge("RESPONSE.json")
      }
      let response = try JSONDecoder().decode(AgentResponseConfiguration.self, from: data)
      try response.validate()
      closeAttempted = true
      try handle.close()
      return response
    } catch {
      let primary = error
      guard !closeAttempted else { throw primary }
      closeAttempted = true
      do {
        try handle.close()
      } catch {
        throw AgentError.persistenceFailure(
          "Reading RESPONSE.json failed: \(primary); file descriptor cleanup failed: \(error)"
        )
      }
      throw primary
    }
  }

  func setResponseConfiguration(agentID: String, _ value: AgentResponseConfiguration) throws {
    try value.validate()
    try mutationFence.withExclusiveMutation("agent.setResponseConfiguration") {
      _ = try loadDefinition(id: agentID)
      try writeJSON(value, to: agentRootURL(id: agentID).appendingPathComponent("RESPONSE.json"), atomic: true)
    }
  }

  func promptSnapshot(agentID: String) throws -> AgentPromptSnapshot {
    let definition = try loadDefinition(id: agentID)
    let rawSoul = try readText(soulURL(id: agentID), required: true)
    let soul = rawSoul.trimmingCharacters(in: .whitespacesAndNewlines)
    let user = try readText(userURL(id: agentID), required: false)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let memory: String
    switch definition.knowledgeOwnership {
    case .localCuratedMemory:
      memory = try readText(memoryURL(id: agentID), required: false)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    case .externalKnowledgeBase:
      memory = ""
    }
    guard !soul.isEmpty else { throw ManagedAgentError.emptySoul }

    var sections = ["# Soul\n\(soul)"]
    if !user.isEmpty { sections.append("# User\n\(user)") }
    if !memory.isEmpty { sections.append("# Memory\n\(memory)") }
    return AgentPromptSnapshot(
      systemPrompt: sections.joined(separator: "\n\n"),
      soulDigest: SHA256HexDigest.digest(rawSoul)
    )
  }

  func skillWorkspace(agentID: String) throws -> SkillWorkspace {
    _ = try loadDefinition(id: agentID)
    let root = agentRootURL(id: agentID)
    return SkillWorkspace(
      supportRootURL: root,
      userSkillsRootURL: root.appendingPathComponent("skills", isDirectory: true)
    )
  }

  private var agentsRootURL: URL {
    dataStore.rootURL.appendingPathComponent("agents", isDirectory: true)
  }

  private var mutationFence: AgentWorkspaceMutationFence {
    AgentWorkspaceMutationFence(agentsRootURL: agentsRootURL)
  }

  private func agentRootURL(id: String) -> URL {
    agentsRootURL.appendingPathComponent(id, isDirectory: true)
  }

  private func profileURL(id: String) -> URL {
    agentRootURL(id: id).appendingPathComponent("agent.json", isDirectory: false)
  }

  private func soulURL(id: String) -> URL {
    agentRootURL(id: id).appendingPathComponent("SOUL.md", isDirectory: false)
  }

  private func userURL(id: String) -> URL {
    agentRootURL(id: id).appendingPathComponent("USER.md", isDirectory: false)
  }

  private func memoryURL(id: String) -> URL {
    agentRootURL(id: id).appendingPathComponent("MEMORY.md", isDirectory: false)
  }

  private func loadDefinition(id: String) throws -> AgentDefinition {
    try AgentIdentity.validate(id: id)
    let url = profileURL(id: id)
    guard fileManager.fileExists(atPath: url.path) else { throw ManagedAgentError.notFound(id) }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let definition = try decoder.decode(AgentDefinition.self, from: data)
    guard definition.id == id, definition.schemaVersion == AgentDefinition.currentSchemaVersion
    else {
      throw ManagedAgentError.invalidDefinition
    }
    return definition
  }

  private func validateDocument(
    _ value: String,
    name: String,
    maximumBytes: Int,
    allowEmpty: Bool
  ) throws {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !allowEmpty, normalized.isEmpty { throw ManagedAgentError.emptySoul }
    guard value.utf8.count <= maximumBytes else { throw ManagedAgentError.documentTooLarge(name) }
  }

  private func readText(_ url: URL, required: Bool) throws -> String {
    guard fileManager.fileExists(atPath: url.path) else {
      if required { throw ManagedAgentError.invalidDefinition }
      return ""
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func writeText(_ value: String, to url: URL, atomic: Bool = false) throws {
    let data = Data(value.utf8)
    if atomic {
      try data.write(to: url, options: [.atomic])
    } else {
      try data.write(to: url)
    }
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL, atomic: Bool = false) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: url, options: atomic ? [.atomic] : [])
  }
}
