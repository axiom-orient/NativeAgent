import Foundation
import LanguageModelCore
@preconcurrency import LeapSDK

protocol LeapVoiceSession: AnyObject, Sendable {
  func generate(
    request: LeapVoiceRequest,
    emit: @escaping @Sendable (LeapVoiceEvent) -> Void
  ) async throws
  func shutdown() async throws
}

struct LeapVoiceSessionLoader: Sendable {
  var load: @Sendable (URL) async throws -> any LeapVoiceSession
}

extension LeapVoiceSessionLoader {
  static let live = Self { directory in
    let runner = try await LeapInferenceEngine.shared.loadModel(
      modelPath: directory.appending(path: "LFM2.5-Audio-1.5B-Q4_0.gguf").path,
      mmprojPath: directory.appending(path: "mmproj-LFM2.5-Audio-1.5B-Q4_0.gguf").path,
      audioDecoderPath: directory.appending(path: "vocoder-LFM2.5-Audio-1.5B-Q4_0.gguf").path,
      audioTokenizerPath: nil,
      options: nil,
      generationTimeParameters: nil)
    return LeapLiveSession(runner: runner)
  }
}

private final class LeapLiveSession: LeapVoiceSession, @unchecked Sendable {
  private let runner: any ModelRunner

  init(runner: any ModelRunner) { self.runner = runner }

  func generate(
    request: LeapVoiceRequest,
    emit: @escaping @Sendable (LeapVoiceEvent) -> Void
  ) async throws {
    try request.validate()
    let systemPrompt: String
    let message: ChatMessage
    switch request {
    case .transcribeEnglish(let input):
      systemPrompt = "Perform ASR."
      message = ChatMessage(
        role: .user,
        content: try ChatMessageContent.fromFloatSamples(
          input.samples, sampleRate: input.sampleRate))
    case .synthesizeEnglish(let text, let voice):
      systemPrompt = voice.systemPrompt
      message = ChatMessage(role: .user, textContent: text)
    case .speechToSpeechEnglish(let input):
      systemPrompt = "Respond with interleaved text and audio."
      message = ChatMessage(
        role: .user,
        content: try ChatMessageContent.fromFloatSamples(
          input.samples, sampleRate: input.sampleRate))
    }
    let conversation: any LeapSDK.Conversation
    if case .speechToSpeechEnglish = request {
      // LFM Audio's interleaved path is defined by an explicit system history.
      // Keeping it distinct from the convenience prompt path avoids the native
      // S2S crash previously observed with an invalid conversation envelope.
      conversation = Conversation(
        modelRunner: runner,
        history: [ChatMessage(role: .system, textContent: systemPrompt)])
    } else {
      conversation = runner.createConversation(systemPrompt: systemPrompt)
    }
    // LEAP's public generation contract exposes this bound through
    // GenerationOptions. Keeping it finite is important for audio turns:
    // an unbounded response can keep producing repeated text/audio tokens and
    // eventually enter the native detokenizer with an invalid view.
    let generationOptions = GenerationOptions()
      .with(maxTokens: LeapLimits.maxGenerationTokens)
    var completed = false
    var sampleRate: Int?
    var audioSamples = 0
    var audioChunks = 0
    var textBytes = 0
    var repeatedTextChunks = 0
    var lastMeaningfulTextChunk: String?
    for await response in conversation.generateResponse(
      message: message, generationOptions: generationOptions)
    {
      try Task.checkCancellation()
      if let chunk = response as? MessageResponseChunk {
        guard !completed else { throw LeapError.invalidRuntimeOutput }
        let bytes = chunk.text.utf8.count
        guard bytes <= LeapLimits.maxTextBytes - textBytes else {
          throw LeapError.outputLimitExceeded
        }
        textBytes += bytes
        let meaningful = chunk.text
          .lowercased()
          .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
          .joined(separator: " ")
        if meaningful.utf8.count >= 12 {
          if meaningful == lastMeaningfulTextChunk {
            repeatedTextChunks += 1
          } else {
            repeatedTextChunks = 0
            lastMeaningfulTextChunk = meaningful
          }
          guard repeatedTextChunks < LeapLimits.maxRepeatedTextChunks else {
            throw LeapError.outputLimitExceeded
          }
        }
        switch request {
        case .transcribeEnglish: emit(.transcriptDelta(chunk.text))
        case .speechToSpeechEnglish: emit(.textDelta(chunk.text))
        case .synthesizeEnglish: break
        }
      } else if let audio = response as? MessageResponseAudioSample {
        guard !completed else { throw LeapError.invalidRuntimeOutput }
        let rate = Int(audio.sampleRate)
        let samples = audio.samples.toFloatArray()
        guard rate == 24_000, sampleRate == nil || sampleRate == rate,
          samples.allSatisfy(\.isFinite)
        else { throw LeapError.invalidRuntimeOutput }
        guard audioSamples <= rate * LeapLimits.maxOutputSeconds - samples.count else {
          throw LeapError.outputLimitExceeded
        }
        // Cut before the native detokenizer can reach its own fatal tensor
        // boundary; the caller recovers via segmentation halving.
        guard audioChunks < LeapLimits.maxOutputChunks - 1 else {
          throw LeapError.outputLimitExceeded
        }
        sampleRate = rate
        audioSamples += samples.count
        audioChunks += 1
        emit(.pcm(samples: samples, sampleRate: rate))
      } else if response is MessageResponseReasoningChunk {
        // Sampler draws sometimes lead with thinking tokens; they carry no
        // user payload for ASR/TTS/S2S. Discard them - the shared event-count
        // cap and the inactivity watchdog still bound pathological streams.
        guard !completed else { throw LeapError.invalidRuntimeOutput }
      } else if response is MessageResponseFunctionCalls {
        // Speech capabilities never emit tool calls.
        throw LeapError.invalidRuntimeOutput
      } else if response is MessageResponseError {
        throw LeapError.nativeFailure
      } else if let complete = response as? MessageResponseComplete {
        guard !completed else { throw LeapError.invalidRuntimeOutput }
        switch complete.finishReason {
        case .stop:
          break
        case .exceedContext, .constraint:
          // A cap/interrupted response is not a successful terminal. Do not
          // manufacture `.completed` from partial text or PCM.
          throw LeapError.outputLimitExceeded
        case .interrupted:
          throw LeapError.generationInterrupted
        case .error:
          throw LeapError.nativeFailure
        }
        completed = true
        let usage = try LeapVoiceUsage(
          promptTokens: complete.stats?.promptTokens,
          completionTokens: complete.stats?.completionTokens,
          tokensPerSecond: complete.stats?.tokenPerSecond)
        emit(.completed(usage))
      } else {
        throw LeapError.invalidRuntimeOutput
      }
    }
    guard completed else { throw LeapError.invalidRuntimeOutput }
    switch request {
    case .transcribeEnglish:
      guard textBytes > 0, audioSamples == 0 else { throw LeapError.invalidRuntimeOutput }
    case .synthesizeEnglish:
      guard audioSamples > 0 else { throw LeapError.invalidRuntimeOutput }
    case .speechToSpeechEnglish:
      guard textBytes > 0, audioSamples > 0 else { throw LeapError.invalidRuntimeOutput }
    }
  }

  func shutdown() async throws { try await runner.unload() }
}

/// Events emitted by the text-only native seam.  Terminal validation remains
/// in the runtime so injected sessions and the live LEAP adapter share the
/// same bounded lifecycle policy.
enum LeapTextRole: Sendable, Equatable {
  case system
  case user
  case assistant
}

struct LeapTextMessage: Sendable, Equatable {
  let role: LeapTextRole
  let content: String
}

enum LeapTextEvent: Sendable {
  case text(String)
  case completed
}

protocol LeapTextSession: AnyObject, Sendable {
  func generate(
    history: [LeapTextMessage],
    userMessage: String,
    outputFormat: ModelOutputFormat,
    emit: @escaping @Sendable (LeapTextEvent) -> Void
  ) async throws
  func shutdown() async throws
}

struct LeapTextSessionLoader: Sendable {
  var load: @Sendable (URL) async throws -> any LeapTextSession
}

extension LeapTextSessionLoader {
  static let live = Self { fileURL in
    // QAD is a text-only GGUF. Use the local-file API with companion-file
    // discovery disabled so a neighboring projector or audio asset can never
    // be pulled into this resident session. mmap keeps the approximately
    // 696 MB weights file file-backed and makes its pages reclaimable under
    // memory pressure. The 8,192-token context leaves useful headroom for
    // multi-turn text while remaining a finite device-side allocation.
    let options = LiquidInferenceEngineOptions(
      bundlePath: fileURL.path,
      cacheOptions: nil,
      cpuThreads: KotlinUInt(4),
      cpuAffinity: LeapSDK.CpuAffinity.PerformanceCores.shared,
      contextSize: KotlinUInt(value: LeapLimits.textContextTokens),
      nGpuLayers: nil,
      mmProjPath: nil,
      audioDecoderPath: nil,
      chatTemplate: nil,
      audioTokenizerPath: nil,
      audioDecoderUseGpu: false,
      useMmap: KotlinBoolean(true),
      loraAdapters: nil,
      extras: nil)
    let runner = try await Leap.shared.load(
      url: fileURL,
      options: options,
      generationTimeParameters: nil,
      autoDetectCompanionFiles: false)
    return LeapLiveTextSession(runner: runner)
  }
}

private final class LeapLiveTextSession: LeapTextSession, @unchecked Sendable {
  private let runner: any ModelRunner

  init(runner: any ModelRunner) { self.runner = runner }

  func generate(
    history: [LeapTextMessage],
    userMessage: String,
    outputFormat: ModelOutputFormat,
    emit: @escaping @Sendable (LeapTextEvent) -> Void
  ) async throws {
    let nativeHistory = history.map { message in
      let role: ChatMessage.Role = switch message.role {
      case .system: .system
      case .user: .user
      case .assistant: .assistant
      }
      return ChatMessage(role: role, textContent: message.content)
    }
    let conversation: any LeapSDK.Conversation =
      nativeHistory.isEmpty
      ? runner.createConversation(systemPrompt: nil)
      : runner.createConversationFromHistory(history: nativeHistory)
    let options = try LeapTextGenerationPolicy.options(for: outputFormat)
    for await response in conversation.generateResponse(
      message: ChatMessage(role: .user, textContent: userMessage),
      generationOptions: options)
    {
      try Task.checkCancellation()
      if let chunk = response as? MessageResponseChunk {
        emit(.text(chunk.text))
      } else if response is MessageResponseReasoningChunk {
        // Reasoning is native metadata, not user-visible text. It is not a
        // heartbeat; the runtime's event and inactivity bounds still apply.
      } else if let error = response as? MessageResponseError {
        throw ModelGenerationFailure(.transportFailure,
          "LEAP native generation failed: \(String(error.message.prefix(512)))")
      } else if response is MessageResponseFunctionCalls {
        throw LeapError.invalidRuntimeOutput
      } else if let complete = response as? MessageResponseComplete {
        switch complete.finishReason {
        case .stop:
          emit(.completed)
        case .exceedContext, .constraint:
          throw LeapError.outputLimitExceeded
        case .interrupted:
          throw LeapError.generationInterrupted
        case .error:
          throw ModelGenerationFailure(.transportFailure, "LEAP text generation ended with error finish reason.")
        }
      } else {
        throw LeapError.invalidRuntimeOutput
      }
    }
  }

  func shutdown() async throws { try await runner.unload() }
}

/// Conservative sampling for constrained generation; this is provider policy,
/// independent of the caller-owned output schema.
enum LeapTextGenerationPolicy {
  static let structuredOutputTemperature: Float = 0.1
  // llama.cpp expands bounded repetitions into grammar rules. Its parser rejects
  // this threshold; the pinned LEAP SDK otherwise logs the error and runs unconstrained.
  static let nativeRepetitionThreshold: Int64 = 2_000

  static func validate(_ format: ModelOutputFormat) throws {
    try format.validate()
    if case .jsonObject(let schema) = format { try validateStringBounds(schema) }
  }

  private static func validateStringBounds(_ schema: JSONValue) throws {
    guard case .object(let node) = schema else { return }
    for key in ["minLength", "maxLength"] {
      guard let value = node[key] else { continue }
      let bound: Double
      switch value {
      case .integer(let count): bound = Double(count)
      case .number(let count): bound = count
      default: throw ModelGenerationFailure(.invalidRequest, "LEAP schema \(key) must be an integer.")
      }
      guard bound.isFinite, bound >= 0, bound.rounded(.towardZero) == bound,
            bound < Double(nativeRepetitionThreshold) else {
        throw ModelGenerationFailure(.invalidRequest,
          "LEAP schema \(key) must be below \(nativeRepetitionThreshold). Enforce larger output limits in bytes outside the grammar.")
      }
    }
    // Only schema-bearing children are walked. Examples/default/const/enum are
    // user data and may legitimately contain fields named minLength/maxLength.
    for key in ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"] {
      if case .object(let children) = node[key] {
        for child in children.values { try validateStringBounds(child) }
      }
    }
    for key in ["items", "additionalProperties", "unevaluatedProperties", "propertyNames", "contains", "not", "if", "then", "else", "allOf", "anyOf", "oneOf", "prefixItems"] {
      guard let child = node[key] else { continue }
      if case .array(let children) = child {
        for value in children { try validateStringBounds(value) }
      } else { try validateStringBounds(child) }
    }
  }
  static func options(for outputFormat: ModelOutputFormat) throws -> GenerationOptions {
    try validate(outputFormat)
    var options = GenerationOptions()
      .with(maxTokens: LeapLimits.maxTextGenerationTokens)
    if case .jsonObject(let schema) = outputFormat {
      // The request owns the schema; the native decoder enforces it.
      // Plain text retains the model defaults and existing behavior.
      options = options.with(jsonSchema: try schema.canonicalString())
        .with(temperature: LeapTextGenerationPolicy.structuredOutputTemperature)
    }
    return options
  }
}
