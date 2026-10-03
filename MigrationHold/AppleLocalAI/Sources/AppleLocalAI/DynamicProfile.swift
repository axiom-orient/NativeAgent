import AppleLocalAICore
import FoundationModels

extension SessionPropertyValues {
  @SessionPropertyEntry
  var appleLocalAIProfile: AppleLocalAIProfile? = nil

  @SessionPropertyEntry
  var appleLocalAIToolCallCount: Int = 0
}

struct AppleLocalAIDynamicInstructions: DynamicInstructions, Sendable {
  let instructions: Instructions
  let tools: [any Tool]

  var body: some DynamicInstructions {
    Instructions(instructions)
    tools
  }
}

/// The single root dynamic profile for a session. Configuration changes update a
/// session property; the Foundation Models session and its transcript stay intact.
struct AppleLocalAIRootProfile: LanguageModelSession.DynamicProfile {
  @SessionProperty(\.appleLocalAIProfile) var profile

  var body: some LanguageModelSession.DynamicProfile {
    if let profile {
      AppleLocalAIConfiguredProfile(configuration: profile)
    } else {
      LanguageModelSession.Profile { Instructions("") }
        .onPrompt { _ in throw AppleLocalAIError.profileUnavailable }
    }
  }
}

struct AppleLocalAIConfiguredProfile: LanguageModelSession.DynamicProfile {
  let configuration: AppleLocalAIProfile
  @SessionProperty(\.appleLocalAIToolCallCount) var toolCallCount

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      AppleLocalAIDynamicInstructions(
        instructions: configuration.nativeInstructions,
        tools: configuration.tools
      )
    }
    .model(configuration.model)
    .temperature(configuration.temperature)
    .samplingMode(configuration.samplingMode)
    .maximumResponseTokens(configuration.maximumResponseTokens)
    .reasoningLevel(configuration.reasoningLevel)
    .toolCallingMode(effectiveToolCallingMode)
    .historyTransform { history in Self.projectHistory(history, policy: configuration.historyPolicy) }
    .transcriptErrorHandlingPolicy(configuration.transcriptErrorHandlingPolicy)
    .onPrompt { _ in toolCallCount = 0 }
    .onToolCall { _ in toolCallCount += 1 }
  }

  private var effectiveToolCallingMode: GenerationOptions.ToolCallingMode? {
    guard configuration.toolCallingMode == .required else {
      return configuration.toolCallingMode
    }
    return toolCallCount == 0 ? .required : .allowed
  }

  /// Provider-specific reasoning is retained by the canonical native transcript,
  /// but omitted from replay when a profile invokes another model.
  private static func projectHistory(
    _ history: [Transcript.Entry],
    policy: AppleLocalAIHistoryPolicy
  ) -> [Transcript.Entry] {
    let portable = history.filter { entry in
      if case .reasoning = entry { return false }
      return true
    }

    switch policy {
    case .full:
      return portable
    case .recentEntries(let limit):
      let kinds: [HistoryEntryKind] = portable.map { entry in
        switch entry {
        case .prompt: .prompt
        case .toolCalls: .toolCalls
        case .toolOutput: .toolOutput
        default: .other
        }
      }
      return Array(portable[HistoryWindow.retainedRange(in: kinds, limit: limit)])
    }
  }
}
