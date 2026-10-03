import Foundation
@preconcurrency import LeapSDK

/// The official LEAP binary version used by this package.
@available(iOS 27.0, macOS 27.0, *)
public enum AppleLocalAILEAP {
  public static let leapSDKVersion = "0.10.13-SNAPSHOT"
}

/// Exact model artifacts supported by the direct AppleLocalAI LEAP adapter.
///
/// The model identity contains the upstream repository revision, file size,
/// and SHA-256. A file with the same name but different bytes is never loaded.
@available(iOS 27.0, macOS 27.0, *)
public enum AppleLocalAILEAPTextModel: String, CaseIterable, Hashable, Sendable {
  case lfm2_5_230M_q4_0

  public static let `default`: Self = .lfm2_5_230M_q4_0

  public var repositoryID: String { "LiquidAI/LFM2.5-230M-GGUF" }
  public var revision: String { "cdf97bd8205908758f44aec508d68ac1aef98f5c" }
  public var fileName: String { "LFM2.5-230M-Q4_0.gguf" }
  public var quantization: String { "Q4_0" }
  public var byteCount: UInt64 { 149_080_928 }
  public var sha256: String {
    "430fbec5b1b355e9bb12cd0638c9f2a8f21fedd6eafb4103e42c7e88887daa73"
  }
  public var modelID: String { "LiquidAI/LFM2.5-230M-Q4_0" }
  public var displayName: String { "LFM2.5 230M Q4_0" }
  public var remoteURL: URL {
    // The immutable Hugging Face commit URL prevents a mutable branch from
    // silently replacing a verified production artifact.
    URL(string: "https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF/resolve/\(revision)/\(fileName)")!
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct AppleLocalAILEAPDownloadProgress: Hashable, Sendable {
  public enum Phase: String, Hashable, Sendable {
    case checking
    case downloading
    case verifying
    case ready
  }

  public let phase: Phase
  public let completedBytes: UInt64
  public let totalBytes: UInt64
  public let currentFile: String

  public var fractionCompleted: Double {
    guard totalBytes > 0 else { return 0 }
    return min(1, Double(completedBytes) / Double(totalBytes))
  }
}

/// A verified local artifact token. It contains no native runner and therefore
/// cannot leak LEAP state into the host session or Foundation Models transcript.
@available(iOS 27.0, macOS 27.0, *)
public struct AppleLocalAILEAPPreparedTextModel: Hashable, Sendable {
  public let model: AppleLocalAILEAPTextModel
  public let localURL: URL

  fileprivate init(model: AppleLocalAILEAPTextModel, localURL: URL) {
    self.model = model
    self.localURL = localURL
  }
}

/// Owns model acquisition and one process-resident LEAP runner.
///
/// The actor is the only owner of the native runner. Foundation Models receives
/// a thin `LEAPLanguageModel` value that calls back into this actor; it never
/// receives `ModelRunner`, `Conversation`, or a downloader object.
@available(iOS 27.0, macOS 27.0, *)
public actor AppleLocalAILEAPRuntime {
  private static let defaultMinimumFreeBytes: UInt64 = 128 * 1024 * 1024
  private static let contextSize: UInt32 = 4_096
  private static let cpuThreads: UInt32 = 4
  private static let warmupMaximumTokens: Int32 = 1
  private static let warmupPrompt = "Hi"

  private let rootURL: URL
  private let minimumFreeBytes: UInt64
  private var residentModel: AppleLocalAILEAPTextModel?
  private var runner: (any ModelRunner)?
  private var activity: LEAPRuntimeActivity = .idle
  private var warmupTask: Task<Void, Error>?
  private var warmedModel: AppleLocalAILEAPTextModel?

  public init(
    rootURL: URL,
    minimumFreeBytes: UInt64 = 128 * 1024 * 1024
  ) throws {
    self.rootURL = rootURL.standardizedFileURL
    self.minimumFreeBytes = minimumFreeBytes
    try FileManager.default.createDirectory(
      at: self.rootURL,
      withIntermediateDirectories: true)
  }

  @discardableResult
  public func prepareTextModel(
    _ model: AppleLocalAILEAPTextModel = .default,
    progress: (@Sendable (AppleLocalAILEAPDownloadProgress) -> Void)? = nil
  ) async throws -> AppleLocalAILEAPPreparedTextModel {
    let artifact = LEAPArtifactFile(
      fileName: model.fileName,
      remoteURL: model.remoteURL,
      byteCount: model.byteCount,
      sha256: model.sha256)
    let paths = try await LEAPArtifactStore.prepare(
      files: [artifact],
      rootURL: rootURL,
      minimumFreeBytes: minimumFreeBytes,
      progress: progress)
    guard let localURL = paths.first else {
      throw AppleLocalAILEAPError.invalidRuntimeOutput
    }
    return AppleLocalAILEAPPreparedTextModel(model: model, localURL: localURL)
  }

  /// Loads an already verified artifact into the one resident native runner.
  /// Downloading and loading are deliberately separate lifecycle operations.
  public func makeTextModel(
    from prepared: AppleLocalAILEAPPreparedTextModel
  ) async throws -> LEAPLanguageModel {
    try Task.checkCancellation()
    guard !activity.isBusy, warmupTask == nil else {
      throw AppleLocalAILEAPError.modelBusy
    }
    // Compare canonical paths rather than URL values. On a device, the
    // application-support URL can carry equivalent but differently encoded
    // URL components even when both URLs address the same directory.
    let preparedDirectory = prepared.localURL
      .deletingLastPathComponent()
      .standardizedFileURL
      .path
    guard preparedDirectory == rootURL.path else {
      throw AppleLocalAILEAPError.modelNotPrepared
    }
    try LEAPArtifactStore.validate(
      file: prepared.localURL,
      against: LEAPArtifactFile(
        fileName: prepared.model.fileName,
        remoteURL: prepared.model.remoteURL,
        byteCount: prepared.model.byteCount,
        sha256: prepared.model.sha256))

    if residentModel != prepared.model || runner == nil {
      guard runner == nil else { throw AppleLocalAILEAPError.modelBusy }
      let options = LiquidInferenceEngineOptions(
        bundlePath: prepared.localURL.path,
        cacheOptions: nil,
        contextSize: Self.contextSize,
        cpuThreads: Self.cpuThreads,
        cpuAffinity: CpuAffinity.PerformanceCores.shared,
        nGpuLayers: nil,
        mmProjPath: nil,
        audioDecoderPath: nil,
        chatTemplate: nil,
        audioTokenizerPath: nil,
        audioDecoderUseGpu: false,
        useMmap: true,
        loraAdapters: nil,
        extras: nil)
      // Reserve before suspension. Other callers cannot load/generate/unload this actor
      // until the native call returns, including when its caller is cancelled.
      activity = .loading
      defer { activity = .idle }
      do {
        runner = try await Leap.shared.load(
          url: prepared.localURL,
          options: options,
          generationTimeParameters: nil,
          autoDetectCompanionFiles: false)
        residentModel = prepared.model
        warmedModel = nil
      } catch {
        runner = nil
        residentModel = nil
        throw AppleLocalAILEAPError.nativeFailure(String(describing: error))
      }
    }
    // A cancelled load may still have acquired native resources. Keep them owned by
    // this actor for explicit unload, but do not publish a successful model handle.
    try Task.checkCancellation()
    return LEAPLanguageModel(runtime: self, model: prepared.model)
  }

  /// Runs the same bounded native warm-up used by the Foundation Models
  /// executor's `prewarm` callback and waits for it to finish.
  ///
  /// Model loading maps and initializes the weights, but it does not force the
  /// first conversation/generation path through LEAP. This method performs a
  /// one-token private probe on a disposable native conversation. The probe is
  /// never sent through `LanguageModelSession`, so it cannot change the public
  /// transcript or its usage.
  public func prewarmTextModel() async throws {
    guard let model = residentModel, runner != nil else {
      throw AppleLocalAILEAPError.modelNotPrepared
    }
    try await prewarmTextModel(model: model)
  }

  /// Internal bridge used by `LEAPExecutor`. Keeping the warm-up here means
  /// the executor never owns or touches a native `Conversation`.
  func prewarmTextModel(model: AppleLocalAILEAPTextModel) async throws {
    guard activity != .loading, activity != .unloading else {
      throw AppleLocalAILEAPError.modelBusy
    }
    guard residentModel == model, runner != nil else {
      throw AppleLocalAILEAPError.modelNotPrepared
    }
    if warmedModel == model { return }

    let task: Task<Void, Error>
    if let existing = warmupTask {
      task = existing
    } else {
      guard !activity.isBusy else { throw AppleLocalAILEAPError.modelBusy }
      task = Task { [self] in
        try await runNativeWarmup(model: model)
      }
      warmupTask = task
    }

    do {
      try await task.value
      if warmupTask == task {
        warmupTask = nil
        warmedModel = model
      }
    } catch {
      if warmupTask == task { warmupTask = nil }
      throw error
    }
    try Task.checkCancellation()
  }

  private func runNativeWarmup(model: AppleLocalAILEAPTextModel) async throws {
    guard residentModel == model, let runner else {
      throw AppleLocalAILEAPError.modelNotPrepared
    }
    guard !activity.isBusy else { throw AppleLocalAILEAPError.modelBusy }
    activity = .generating
    defer { activity = .idle }

    let conversation = runner.createConversation(systemPrompt: nil)
    let options = GenerationOptions()
      .with(maxTokens: Self.warmupMaximumTokens)
      .with(temperature: 0.1)
      .with(topK: 50)
      .with(repetitionPenalty: 1.05)

    var terminalSeen = false
    try await withTaskCancellationHandler {
      for await response in conversation.generateResponse(
        message: ChatMessage(role: .user, textContent: Self.warmupPrompt),
        generationOptions: options)
      {
        try Task.checkCancellation()
        if response is MessageResponseChunk {
          continue
        } else if response is MessageResponseReasoningChunk {
          continue
        } else if response is MessageResponseFunctionCalls {
          throw AppleLocalAILEAPError.nativeFailure(
            "LEAP emitted a function call during native prewarm.")
        } else if let error = response as? MessageResponseError {
          throw AppleLocalAILEAPError.nativeFailure(
            "LEAP prewarm returned an error: \(error.message)")
        } else if let complete = response as? MessageResponseComplete {
          guard !terminalSeen else { throw AppleLocalAILEAPError.invalidRuntimeOutput }
          switch complete.finishReason {
          case .stop, .constraint:
            terminalSeen = true
          case .exceedContext:
            throw AppleLocalAILEAPError.outputLimitExceeded
          case .interrupted:
            throw CancellationError()
          case .error:
            throw AppleLocalAILEAPError.nativeFailure(
              "LEAP prewarm ended with an error finish reason.")
          }
        } else {
          throw AppleLocalAILEAPError.invalidRuntimeOutput
        }
      }
    } onCancel: {
      // Cancelling the async-flow collector invokes LEAP's native stop hook.
      // The SDK documents this as the supported cancellation boundary.
    }

    guard terminalSeen else { throw AppleLocalAILEAPError.invalidRuntimeOutput }
  }

  /// Releases the process-resident native weights. It never deletes the
  /// verified on-disk artifact, so a later load does not require a download.
  public func unload() async throws {
    guard !activity.isBusy, warmupTask == nil else {
      throw AppleLocalAILEAPError.modelBusy
    }
    guard let runner else {
      residentModel = nil
      warmedModel = nil
      return
    }
    activity = .unloading
    defer { activity = .idle }
    do {
      try await runner.unload()
      self.runner = nil
      residentModel = nil
      warmupTask = nil
      warmedModel = nil
    } catch {
      throw AppleLocalAILEAPError.nativeFailure(String(describing: error))
    }
  }

  func generate(
    model: AppleLocalAILEAPTextModel,
    plan: LEAPTranscriptPlan,
    emit: @escaping @Sendable (LEAPRuntimeEvent) async -> Void
  ) async throws {
    guard residentModel == model, runner != nil else {
      throw AppleLocalAILEAPError.modelNotPrepared
    }

    if let warmupTask {
      do {
        try await warmupTask.value
      } catch {
        if self.warmupTask == warmupTask { self.warmupTask = nil }
        throw error
      }
      if self.warmupTask == warmupTask {
        self.warmupTask = nil
        self.warmedModel = model
      }
      try Task.checkCancellation()
    }
    try Task.checkCancellation()
    guard !activity.isBusy else { throw AppleLocalAILEAPError.modelBusy }
    // Re-read the resident after suspension, rather than using a potentially
    // unloaded runner captured before another caller completed the warmup.
    guard residentModel == model, let runner else {
      throw AppleLocalAILEAPError.modelNotPrepared
    }
    activity = .generating
    defer { activity = .idle }

    let nativeHistory = plan.messages.map { message in
      let role: ChatMessage.Role = switch message.role {
      case .system: .system
      case .user: .user
      case .assistant: .assistant
      }
      return ChatMessage(role: role, textContent: message.content)
    }
    let conversation: any Conversation = nativeHistory.isEmpty
      ? runner.createConversation(systemPrompt: nil)
      : runner.createConversationFromHistory(history: nativeHistory)

    var options = GenerationOptions()
      .with(maxTokens: plan.maximumTokens)
      .with(temperature: 0.1)
      .with(topK: 50)
      .with(repetitionPenalty: 1.05)
    if let schema = plan.schemaJSON {
      options = options.with(jsonSchema: schema)
    }

    var outputBytes = 0
    var terminalSeen = false
    var usage: LEAPGenerationUsage?
    try await withTaskCancellationHandler {
      for await response in conversation.generateResponse(
        message: ChatMessage(role: .user, textContent: plan.userMessage),
        generationOptions: options)
      {
        try Task.checkCancellation()
        if let chunk = response as? MessageResponseChunk {
          guard !terminalSeen else { throw AppleLocalAILEAPError.invalidRuntimeOutput }
          let bytes = chunk.text.utf8.count
          let (newTotal, overflow) = outputBytes.addingReportingOverflow(bytes)
          guard !overflow, newTotal <= plan.maximumOutputBytes else {
            throw AppleLocalAILEAPError.outputLimitExceeded
          }
          outputBytes = newTotal
          if !chunk.text.isEmpty { await emit(.textDelta(chunk.text)) }
        } else if response is MessageResponseReasoningChunk {
          // LEAP reasoning is native metadata and is not part of the text
          // contract exposed by this adapter.
        } else if response is MessageResponseFunctionCalls {
          throw AppleLocalAILEAPError.nativeFailure("The text model emitted a function call.")
        } else if response is MessageResponseError {
          throw AppleLocalAILEAPError.nativeFailure("LEAP returned a generation error.")
        } else if let complete = response as? MessageResponseComplete {
          guard !terminalSeen else { throw AppleLocalAILEAPError.invalidRuntimeOutput }
          usage = complete.stats.flatMap(LEAPGenerationUsage.init)
          switch complete.finishReason {
          case .stop:
            terminalSeen = true
          case .exceedContext, .constraint:
            throw AppleLocalAILEAPError.outputLimitExceeded
          case .interrupted:
            throw CancellationError()
          case .error:
            throw AppleLocalAILEAPError.nativeFailure("LEAP ended with an error finish reason.")
          }
        } else {
          throw AppleLocalAILEAPError.invalidRuntimeOutput
        }
      }
    } onCancel: {
      // Cancelling the async-flow collector invokes LEAP's native stop hook.
      // This is the SDK-supported cancellation boundary for a Conversation.
    }
    guard terminalSeen, outputBytes > 0 else {
      throw AppleLocalAILEAPError.invalidRuntimeOutput
    }
    await emit(.completed(usage))
  }

}

/// A provider-neutral usage snapshot. The native `GenerationStats` type stops
/// at the LEAP runtime boundary; Foundation Models receives only these counts.
struct LEAPGenerationUsage: Equatable, Sendable {
  let promptTokens: Int
  let cachedPromptTokens: Int
  let completionTokens: Int

  init(promptTokens: Int, cachedPromptTokens: Int, completionTokens: Int) {
    self.promptTokens = promptTokens
    self.cachedPromptTokens = cachedPromptTokens
    self.completionTokens = completionTokens
  }

  init?(stats: GenerationStats) {
    guard stats.promptTokens >= 0,
      stats.cachedPromptTokens >= 0,
      stats.completionTokens >= 0,
      let promptTokens = Int(exactly: stats.promptTokens),
      let cachedPromptTokens = Int(exactly: stats.cachedPromptTokens),
      let completionTokens = Int(exactly: stats.completionTokens),
      promptTokens.addingReportingOverflow(cachedPromptTokens).overflow == false
    else {
      return nil
    }
    self.init(
      promptTokens: promptTokens,
      cachedPromptTokens: cachedPromptTokens,
      completionTokens: completionTokens)
  }
}

enum LEAPRuntimeEvent: Sendable {
  case textDelta(String)
  case completed(LEAPGenerationUsage?)
}
