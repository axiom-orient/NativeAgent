import Foundation
import FoundationModels

struct LEAPTranscriptMessage: Sendable, Equatable {
  enum Role: Sendable, Equatable {
    case system
    case user
    case assistant
  }

  let role: Role
  let content: String
}

struct LEAPTranscriptPlan: Sendable, Equatable {
  static let defaultMaximumTokens: Int32 = 768
  static let maximumSupportedTokens: Int = 4_096
  static let maximumPromptBytes = 64 * 1_024
  static let maximumOutputBytes = 128 * 1_024

  let messages: [LEAPTranscriptMessage]
  let userMessage: String
  let schemaJSON: String?
  let maximumTokens: Int32
  let maximumOutputBytes: Int

  static func make(
    from request: LanguageModelExecutorGenerationRequest
  ) throws -> Self {
    try validateGenerationOptions(request)

    guard request.enabledToolDefinitions.isEmpty else {
      throw LanguageModelError.unsupportedCapability(
        .init(
          capability: .toolCalling,
          debugDescription: "LEAP text generation does not provide Foundation Models tool calling."
        ))
    }

    var messages: [LEAPTranscriptMessage] = []
    messages.reserveCapacity(request.transcript.count)
    for entry in request.transcript {
      switch entry {
      case .instructions(let instructions):
        guard instructions.toolDefinitions.isEmpty else {
          throw LanguageModelError.unsupportedCapability(
            .init(
              capability: .toolCalling,
              debugDescription: "LEAP text generation does not provide Foundation Models tool calling."
            ))
        }
        let content = try text(of: instructions.segments, entry: entry)
        if !content.isEmpty {
          messages.append(.init(role: .system, content: content))
        }
      case .prompt(let prompt):
        messages.append(.init(
          role: .user,
          content: try text(of: prompt.segments, entry: entry)))
      case .response(let response):
        messages.append(.init(
          role: .assistant,
          content: try text(of: response.segments, entry: entry)))
      case .reasoning:
        // Reasoning is provider metadata and is intentionally not replayed as
        // user-visible model text.
        continue
      case .toolCalls, .toolOutput:
        throw unsupportedTranscript(
          entry,
          "LEAP text generation does not accept tool transcript entries.")
      @unknown default:
        throw unsupportedTranscript(
          entry,
          "The transcript contains an unsupported Foundation Models entry.")
      }
    }

    guard let last = messages.last, last.role == .user,
      !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AppleLocalAILEAPError.noPrompt
    }

    let promptBytes = messages.reduce(0) { partial, message in
      partial + message.content.utf8.count
    }
    guard promptBytes <= maximumPromptBytes else {
      throw AppleLocalAILEAPError.invalidGenerationOptions(
        "The LEAP prompt history cannot exceed \(maximumPromptBytes) UTF-8 bytes.")
    }

    let maximumTokens = try maximumTokens(for: request.generationOptions)
    return Self(
      messages: Array(messages.dropLast()),
      userMessage: last.content,
      schemaJSON: try schemaJSON(for: request.schema),
      maximumTokens: maximumTokens,
      maximumOutputBytes: min(maximumOutputBytes, Int(maximumTokens) * 4))
  }

  private static func validateGenerationOptions(
    _ request: LanguageModelExecutorGenerationRequest
  ) throws {
    if request.generationOptions.temperature != nil
      || request.generationOptions.samplingMode != nil
    {
      throw AppleLocalAILEAPError.invalidGenerationOptions(
        "LEAP owns its native sampling policy; temperature and sampling mode are unsupported by this adapter.")
    }
    if request.contextOptions.reasoningLevel != nil {
      throw LanguageModelError.unsupportedCapability(
        .init(
          capability: .reasoning,
          debugDescription: "The selected LEAP text model does not expose reasoning output."
        ))
    }
  }

  private static func maximumTokens(for options: GenerationOptions) throws -> Int32 {
    let requested = options.maximumResponseTokens ?? Int(defaultMaximumTokens)
    guard (1...maximumSupportedTokens).contains(requested) else {
      throw AppleLocalAILEAPError.invalidGenerationOptions(
        "maximumResponseTokens must be between 1 and \(maximumSupportedTokens) for LEAP.")
    }
    guard requested <= Int(Int32.max) else {
      throw AppleLocalAILEAPError.invalidGenerationOptions(
        "maximumResponseTokens is outside LEAP's native Int32 range.")
    }
    return Int32(requested)
  }

  private static func schemaJSON(for schema: GenerationSchema?) throws -> String? {
    guard let schema else { return nil }
    do {
      let encoded = try JSONEncoder().encode(schema)
      let object = try JSONSerialization.jsonObject(with: encoded, options: [])
      guard object is [String: Any] else { throw AppleLocalAILEAPError.invalidSchema }
      let canonical = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys])
      guard let string = String(data: canonical, encoding: .utf8), !string.isEmpty else {
        throw AppleLocalAILEAPError.invalidSchema
      }
      return string
    } catch let error as AppleLocalAILEAPError {
      throw error
    } catch {
      throw AppleLocalAILEAPError.invalidSchema
    }
  }

  private static func text(
    of segments: [Transcript.Segment],
    entry: Transcript.Entry
  ) throws -> String {
    try segments.map { segment in
      guard case .text(let value) = segment else {
        throw unsupportedTranscript(
          entry,
          "LEAP text generation accepts text transcript segments only.")
      }
      return value.content
    }.joined(separator: " ")
  }

  private static func unsupportedTranscript(
    _ entry: Transcript.Entry,
    _ message: String
  ) -> LanguageModelError {
    .unsupportedTranscriptContent(
      .init(unsupportedContent: [entry], debugDescription: message))
  }
}
