import FoundationModels

public enum AppleLocalAIHistoryPolicy: Sendable {
  case full
  case recentEntries(Int)
}

/// Session configuration, not session state.
/// Foundation Models remains the authority for transcript, tools, model execution,
/// token usage, guided generation, and errors.
public struct AppleLocalAIProfile: Sendable {
  private static let temperatureRange = 0.0...1.0

  public let model: any LanguageModel
  public let instructions: String
  public let nativeInstructions: Instructions
  public let tools: [any Tool]
  public let temperature: Double?
  public let samplingMode: GenerationOptions.SamplingMode?
  public let maximumResponseTokens: Int?
  public let reasoningLevel: ContextOptions.ReasoningLevel?
  public let toolCallingMode: GenerationOptions.ToolCallingMode?
  public let transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy?
  public let historyPolicy: AppleLocalAIHistoryPolicy

  public init(
    model: any LanguageModel = SystemLanguageModel.default,
    instructions: String = "",
    tools: [any Tool] = [],
    temperature: Double? = nil,
    samplingMode: GenerationOptions.SamplingMode? = nil,
    maximumResponseTokens: Int? = nil,
    reasoningLevel: ContextOptions.ReasoningLevel? = nil,
    toolCallingMode: GenerationOptions.ToolCallingMode? = nil,
    transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy? = .revertTranscript,
    historyPolicy: AppleLocalAIHistoryPolicy = .full
  ) throws {
    try self.init(
      model: model,
      instructionsText: instructions,
      nativeInstructions: Instructions(instructions),
      tools: tools,
      temperature: temperature,
      samplingMode: samplingMode,
      maximumResponseTokens: maximumResponseTokens,
      reasoningLevel: reasoningLevel,
      toolCallingMode: toolCallingMode,
      transcriptErrorHandlingPolicy: transcriptErrorHandlingPolicy,
      historyPolicy: historyPolicy
    )
  }

  /// Creates a profile from Apple's native `Instructions` value. This keeps
  /// conditional and collection-based instruction builders intact instead of
  /// flattening them into a second string format.
  public init<InstructionContent: InstructionsRepresentable>(
    model: any LanguageModel = SystemLanguageModel.default,
    nativeInstructions: InstructionContent,
    tools: [any Tool] = [],
    temperature: Double? = nil,
    samplingMode: GenerationOptions.SamplingMode? = nil,
    maximumResponseTokens: Int? = nil,
    reasoningLevel: ContextOptions.ReasoningLevel? = nil,
    toolCallingMode: GenerationOptions.ToolCallingMode? = nil,
    transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy? = .revertTranscript,
    historyPolicy: AppleLocalAIHistoryPolicy = .full
  ) throws {
    try self.init(
      model: model,
      instructionsText: "",
      nativeInstructions: Instructions(nativeInstructions),
      tools: tools,
      temperature: temperature,
      samplingMode: samplingMode,
      maximumResponseTokens: maximumResponseTokens,
      reasoningLevel: reasoningLevel,
      toolCallingMode: toolCallingMode,
      transcriptErrorHandlingPolicy: transcriptErrorHandlingPolicy,
      historyPolicy: historyPolicy
    )
  }

  private init(
    model: any LanguageModel,
    instructionsText: String,
    nativeInstructions: Instructions,
    tools: [any Tool],
    temperature: Double?,
    samplingMode: GenerationOptions.SamplingMode?,
    maximumResponseTokens: Int?,
    reasoningLevel: ContextOptions.ReasoningLevel?,
    toolCallingMode: GenerationOptions.ToolCallingMode?,
    transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy?,
    historyPolicy: AppleLocalAIHistoryPolicy
  ) throws {
    if let maximumResponseTokens, maximumResponseTokens <= 0 {
      throw AppleLocalAIError.invalidMaximumResponseTokens
    }
    if let temperature, !temperature.isFinite || !Self.temperatureRange.contains(temperature) {
      throw AppleLocalAIError.invalidTemperature
    }
    if case .recentEntries(let count) = historyPolicy, count <= 0 {
      throw AppleLocalAIError.invalidHistoryLimit
    }
    if toolCallingMode == .required, tools.isEmpty {
      throw AppleLocalAIError.requiredToolCallingWithoutTools
    }

    self.model = model
    self.instructions = instructionsText
    self.nativeInstructions = nativeInstructions
    self.tools = tools
    self.temperature = temperature
    self.samplingMode = samplingMode
    self.maximumResponseTokens = maximumResponseTokens
    self.reasoningLevel = reasoningLevel
    self.toolCallingMode = toolCallingMode
    self.transcriptErrorHandlingPolicy = transcriptErrorHandlingPolicy
    self.historyPolicy = historyPolicy
  }
}
