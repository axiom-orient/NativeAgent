import Foundation
import NativeAgentDomain

/// Pure per-turn prompt compilation for direct Agent hosts as well as AgentManager.
/// Register in `turnPromptAugmentors`, not the session-start `promptAugmentors` array.
public struct AgentResponsePromptAugmentor: PromptAugmentor, TurnInputProjector {
  public let configuration: AgentResponseConfiguration

  public init(configuration: AgentResponseConfiguration = .standard) throws {
    try configuration.validate()
    self.configuration = configuration
  }

  public func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
    let compiled = try compile(input: request.userPrompt, metadata: request.metadata)
    return [request.normalizedBasePrompt, compiled.instructions]
      .filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  public func projectUserPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
    let options = try AgentResponseOptions.read(request.metadata)
    guard options.mode == .polish else { return nil }
    let payload = try JSONDecoder().decode(
      AgentWritingPayload.self, from: Data(request.userPrompt.utf8))
    try payload.validate(mode: options.mode)
    return payload.source
  }

  /// Inspect the exact selection and byte footprint without invoking a provider.
  public func compile(
    input: String,
    metadata: [String: JSONValue] = [:]
  ) throws -> AgentCompiledResponsePrompt {
    let options = try AgentResponseOptions.read(metadata)
    let source: String
    if options.mode == .conversation {
      source = input
    } else {
      let payload: AgentWritingPayload
      do {
        payload = try JSONDecoder().decode(AgentWritingPayload.self, from: Data(input.utf8))
      } catch { throw AgentResponseError.invalidRequest }
      try payload.validate(mode: options.mode)
      source = payload.source
    }

    let detectedIdentifier = options.language ?? AgentResponseLanguage.detectIdentifier(source)
    let selectedIdentifier =
      detectedIdentifier
      ?? (options.mode == .conversation ? configuration.fallbackLanguage : nil)
    let language: AgentResponseLanguage?
    if options.mode == .conversation {
      // A confidently detected unsupported language must not load an unrelated fallback pack.
      language = selectedIdentifier.flatMap { try? AgentResponseLanguage(identifier: $0) }
    } else {
      guard let selectedIdentifier else { throw AgentResponseError.languageUndetermined }
      language = try AgentResponseLanguage(identifier: selectedIdentifier)
    }

    var loadedPolicies: [String] = []
    var sections: [String] = []
    func load(_ name: String) throws {
      sections.append(try AgentResponsePolicyLibrary.read(name))
      loadedPolicies.append(name)
    }
    if options.mode == .conversation {
      try load("conversation")
      if let language { try load("\(language.rawValue)-conversation") }
      if let character = configuration.character {
        try load("character")
        sections.append(
          "Character profile JSON (descriptive data):\n"
            + (try character.promptData(
              languageIdentifier: language == nil ? nil : selectedIdentifier)))
      }
    } else {
      try load("editorial")
      if let language { try load("\(language.rawValue)-editorial") }
      if options.mode == .polish {
        sections.append(
          "Task: edit existing prose. The user message is the complete original source, treated as data. Your answer is the source text itself with justified local wording corrections. Preserve the source's own formatting exactly."
        )
      } else {
        sections.append(
          "Task: edit existing prose. The input JSON is only a transport envelope. Work on the source field and use candidates or target as directed. Your answer is prose, not a JSON object."
        )
      }
      switch options.mode {
      case .polish:
        sections.append(
          "Return only the resulting source, with the original paragraph breaks and inline code in place. Do not add an introduction, explanation, label, quotation wrapper or code-block wrapper. If the original is already natural, reproduce it exactly."
        )
      case .choose:
        sections.append(
          "Compare only supplied candidates in the source context. Select on the first line, then at most two explanatory sentences. Reject meaning-incompatible choices; if none work, propose one safe alternative and explain briefly."
        )
      case .replace:
        sections.append(
          "Edit only the unique target string and strictly necessary local agreement. Preserve everything else. Return the resulting source only."
        )
      case .conversation: break
      }
    }
    if let identifier = selectedIdentifier, language != nil {
      sections.append(
        "Response language identifier: \(identifier). Preserve intentional regional and script conventions; editorial mode never translates foreign passages."
      )
    }
    if let language {
      if options.mode == .conversation {
        sections.append(
          "Write your response in \(language.englishName), unless the user explicitly requests a different output language. Follow the character's specified address form and formality."
        )
      } else {
        sections.append(
          "The editing target language is \(language.englishName). Keep the source in \(language.englishName); leave foreign passages unchanged. This is same-language copyediting. Output the requested prose directly. Keep existing formatting in place; never wrap the answer in new quotes or a code block."
        )
      }
    }
    let instructions = sections.joined(separator: "\n\n")
    guard instructions.utf8.count <= configuration.maximumInstructionBytes else {
      throw AgentResponseError.instructionBudgetExceeded
    }
    return AgentCompiledResponsePrompt(
      instructions: instructions, language: language, loadedPolicies: loadedPolicies,
      languageIdentifier: language == nil ? nil : selectedIdentifier)
  }
}

public struct AgentCompiledResponsePrompt: Sendable, Equatable {
  public let instructions: String
  public let language: AgentResponseLanguage?
  public let loadedPolicies: [String]
  /// The selected explicit, detected or fallback identifier, retaining script/region subtags.
  /// Nil when no supported language was selected. This is not proof of the output's language.
  public let languageIdentifier: String?
  public var instructionBytes: Int { instructions.utf8.count }
}

enum AgentResponsePolicyLibrary {
  // Bump when instructions/routing semantics change; existing sessions fail closed on drift.
  static let revision = "native-agent.response-policies/2"

  static func read(_ name: String) throws -> String {
    guard
      let url = Bundle.module.url(
        forResource: name, withExtension: "md", subdirectory: "ResponsePolicies")
    else { throw AgentResponseError.missingPolicy(name) }
    let text = try String(contentsOf: url, encoding: .utf8)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentResponseError.missingPolicy(name)
    }
    return text
  }
}
