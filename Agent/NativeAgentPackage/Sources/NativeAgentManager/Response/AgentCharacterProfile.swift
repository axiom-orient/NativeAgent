import Foundation

/// Host-authored character data. This grants no tool, file, network or permission authority.
/// Soul remains the behavioral foundation; these fields customize conversation only.
public struct AgentCharacterProfile: Codable, Hashable, Sendable {
  public let name: String
  public let background: String
  public let personality: String
  public let speakingStyle: String
  public let relationship: String
  public let scenario: String
  public let knowledgeBoundaries: String
  public let examples: [DialogueExample]
  /// Optional language/region-specific voice. Only the closest matching entry enters a turn.
  public let voices: [Voice]

  public struct Voice: Codable, Hashable, Sendable {
    public let language: String
    public let speakingStyle: String
    public let selfReference: String
    public let addressForm: String

    public init(
      language: String, speakingStyle: String,
      selfReference: String = "", addressForm: String = ""
    ) {
      self.language = language
      self.speakingStyle = speakingStyle
      self.selfReference = selfReference
      self.addressForm = addressForm
    }
  }

  public struct DialogueExample: Codable, Hashable, Sendable {
    /// Match examples to the active response language. Examples are never real conversation history.
    public let language: String
    public let user: String
    public let character: String

    public init(language: String, user: String, character: String) {
      self.language = language
      self.user = user
      self.character = character
    }
  }

  public init(
    name: String,
    background: String = "",
    personality: String = "",
    speakingStyle: String = "",
    relationship: String = "",
    scenario: String = "",
    knowledgeBoundaries: String = "",
    examples: [DialogueExample] = [],
    voices: [Voice] = []
  ) throws {
    self.name = name
    self.background = background
    self.personality = personality
    self.speakingStyle = speakingStyle
    self.relationship = relationship
    self.scenario = scenario
    self.knowledgeBoundaries = knowledgeBoundaries
    self.examples = examples
    self.voices = voices
    try validate()
  }

  private enum CodingKeys: String, CodingKey {
    case name, background, personality, speakingStyle, relationship, scenario, knowledgeBoundaries,
      examples, voices
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      name: values.decode(String.self, forKey: .name),
      background: values.decode(String.self, forKey: .background),
      personality: values.decode(String.self, forKey: .personality),
      speakingStyle: values.decode(String.self, forKey: .speakingStyle),
      relationship: values.decode(String.self, forKey: .relationship),
      scenario: values.decode(String.self, forKey: .scenario),
      knowledgeBoundaries: values.decode(String.self, forKey: .knowledgeBoundaries),
      examples: values.decode([DialogueExample].self, forKey: .examples),
      voices: values.decode([Voice].self, forKey: .voices)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(name, forKey: .name)
    try values.encode(background, forKey: .background)
    try values.encode(personality, forKey: .personality)
    try values.encode(speakingStyle, forKey: .speakingStyle)
    try values.encode(relationship, forKey: .relationship)
    try values.encode(scenario, forKey: .scenario)
    try values.encode(knowledgeBoundaries, forKey: .knowledgeBoundaries)
    try values.encode(examples, forKey: .examples)
    try values.encode(voices, forKey: .voices)
  }

  func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      name.utf8.count <= 128, examples.count <= 8, voices.count <= 8,
      try JSONEncoder().encode(self).count <= 6 * 1_024
    else { throw AgentResponseError.invalidCharacterProfile }
    for example in examples {
      _ = try AgentResponseLanguage(identifier: example.language)
      guard !example.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !example.character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw AgentResponseError.invalidCharacterProfile
      }
    }
    var voiceLanguages: Set<String> = []
    for voice in voices {
      _ = try AgentResponseLanguage(identifier: voice.language)
      guard !voice.speakingStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        voiceLanguages.insert(AgentResponseLocale.normalized(voice.language)).inserted
      else { throw AgentResponseError.invalidCharacterProfile }
    }
  }

  func promptData(languageIdentifier: String?) throws -> String {
    let exampleLanguage = AgentResponseLocale.bestMatch(
      for: languageIdentifier, available: examples.map(\.language))
    let voiceLanguage = AgentResponseLocale.bestMatch(
      for: languageIdentifier, available: voices.map(\.language))
    let filtered = try AgentCharacterProfile(
      name: name, background: background, personality: personality,
      speakingStyle: speakingStyle, relationship: relationship, scenario: scenario,
      knowledgeBoundaries: knowledgeBoundaries,
      examples: examples.filter { AgentResponseLocale.normalized($0.language) == exampleLanguage },
      voices: voices.filter { AgentResponseLocale.normalized($0.language) == voiceLanguage }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(filtered), as: UTF8.self)
  }
}

public enum AgentSoul {
  /// A small iOS-oriented foundation. Hosts may supply their own non-empty SOUL.md instead.
  public static let `default` = """
    Help with the user's task and communicate honestly. Distinguish observations, uncertainty, 
    plans and completed actions. Respect privacy, consent and the host's capability boundaries. 
    Use only registered tools and report their actual outcomes. Character performance may shape 
    conversation but never grant permissions, invent real actions or override these commitments.
    """
}
