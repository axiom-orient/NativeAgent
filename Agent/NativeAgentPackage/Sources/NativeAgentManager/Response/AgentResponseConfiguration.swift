import Foundation
import LanguageModelCore

/// Inspectable per-Agent response settings, persisted as RESPONSE.json and pinned per session.
public struct AgentResponseConfiguration: Codable, Hashable, Sendable {
  public static let currentSchemaVersion = "native-agent.response/1"
  public let schemaVersion: String
  public let character: AgentCharacterProfile?
  /// Used only for conversation when detection is uncertain, never to guess an editorial source.
  public let fallbackLanguage: String?
  /// Bounds added instructions, not the source text or provider's token budget.
  public let maximumInstructionBytes: Int

  public init(
    character: AgentCharacterProfile? = nil,
    fallbackLanguage: String? = nil,
    maximumInstructionBytes: Int = 8 * 1_024
  ) throws {
    self.schemaVersion = Self.currentSchemaVersion
    self.character = character
    self.fallbackLanguage = fallbackLanguage
    self.maximumInstructionBytes = maximumInstructionBytes
    try validate()
  }

  public static let standard = Self()

  // Nonthrowing construction for the known-valid default only.
  private init() {
    schemaVersion = Self.currentSchemaVersion
    character = nil
    fallbackLanguage = nil
    maximumInstructionBytes = 8 * 1_024
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, character, fallbackLanguage, maximumInstructionBytes
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(String.self, forKey: .schemaVersion) == Self.currentSchemaVersion else {
      throw AgentResponseError.invalidConfiguration
    }
    try self.init(
      character: values.decodeIfPresent(AgentCharacterProfile.self, forKey: .character),
      fallbackLanguage: values.decodeIfPresent(String.self, forKey: .fallbackLanguage),
      maximumInstructionBytes: values.decode(Int.self, forKey: .maximumInstructionBytes)
    )
  }

  func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion,
      (1_024...16 * 1_024).contains(maximumInstructionBytes)
    else { throw AgentResponseError.invalidConfiguration }
    try character?.validate()
    if let fallbackLanguage { _ = try AgentResponseLanguage(identifier: fallbackLanguage) }
  }

  func snapshotDigest() throws -> String {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let settings = String(decoding: try encoder.encode(self), as: UTF8.self)
    return SHA256HexDigest.digest(AgentResponsePolicyLibrary.revision + "\n" + settings)
  }
}

public enum AgentResponseError: Error, Equatable, Sendable, LocalizedError {
  case invalidCharacterProfile
  case invalidConfiguration
  case unsupportedLanguage(String)
  case languageUndetermined
  case invalidRequest
  case missingPolicy(String)
  case instructionBudgetExceeded
  case snapshotChanged

  public var errorDescription: String? {
    switch self {
    case .invalidCharacterProfile: "Character profile is empty, invalid or exceeds its bounded size."
    case .invalidConfiguration: "Response configuration is invalid or uses an unsupported schema."
    case .unsupportedLanguage(let value): "No built-in response policy for language: \(value)"
    case .languageUndetermined: "Specify the editorial source language; detection is uncertain."
    case .invalidRequest: "Response options or editorial source/candidates/target are invalid."
    case .missingPolicy(let value): "Required bundled response policy is unavailable: \(value)"
    case .instructionBudgetExceeded: "Response instructions exceed the configured byte budget."
    case .snapshotChanged: "Response policy or character changed. Start a new session to adopt it."
    }
  }
}
