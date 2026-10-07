import Foundation
import ModelArtifactStore
import LanguageModelCore

/// Provider-neutral adapter for one explicitly selected text model.
struct LeapModelClient: ModelClientWithOwnedInvocation {
  static let supportedCapabilities: ModelCapabilities = [
    .textInput, .textOutput, .streaming, .structuredOutput,
  ]
  let providerID: String
  let modelDescriptor: ModelDescriptor?
  private let runtime: LeapRuntime
  private let model: LeapTextModel

  init(
    runtime: LeapRuntime,
    model: LeapTextModel,
    providerID: String = "native-agent.leap",
    modelDescriptor: ModelDescriptor? = nil
  ) {
    self.runtime = runtime
    self.model = model
    self.providerID = providerID
    self.modelDescriptor =
      modelDescriptor
      ?? ModelDescriptor(
        id: "lfm2.5-qad-\(model.manifestDigest.rawValue)",
        providerID: providerID,
        displayName: model.repositoryID,
        capabilities: Self.supportedCapabilities)
  }

  func generate(request: ModelRequest) async throws -> ModelTurn {
    try await ModelStreamContract.completedTurn(from: stream(request: request), request: request)
  }

  func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    invocation(request: request, onStarted: {}).events
  }

  func invocation(request: ModelRequest, onStarted: @escaping @Sendable () -> Void)
    -> ModelClientInvocation
  {
    let pair = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    let continuation = pair.continuation
    let task = Task {
      do {
        try Task.checkCancellation()
        let mapped = try Self.map(request)
        if case .terminated = continuation.yield(.started(descriptor: modelDescriptor)) {
          throw CancellationError()
        }
        onStarted()
        try Task.checkCancellation()
        let output = LeapTextOutputAccumulator()
        let isStructured: Bool
        if case .jsonObject = request.outputFormat { isStructured = true } else { isStructured = false }
        let (envelopedLimit, overflow) = request.maxOutputBytes.addingReportingOverflow(LeapJSONOutput.maximumEnvelopeBytes)
        let nativeLimit = isStructured
          ? min(LeapLimits.maxTextGenerationBytes, overflow ? LeapLimits.maxTextGenerationBytes : envelopedLimit)
          : request.maxOutputBytes
        let emit: @Sendable (String) -> Void = { chunk in
          do {
            for delta in try request.limits.boundedDeltas(for: chunk) {
              try output.append(delta, maximumBytes: nativeLimit)
              if !isStructured { continuation.yield(.textDelta(delta)) }
            }
          } catch { output.fail(error) }
        }
        let result = try await runtime.generateTextStream(
          for: model,
          history: mapped.history,
          userMessage: mapped.user,
          outputFormat: request.outputFormat,
          emit: emit)
        try Task.checkCancellation()
        if let failure = output.failure { throw failure }
        guard result == output.value, !output.value.isEmpty else {
          throw LeapError.invalidRuntimeOutput
        }
        let content: String
        if isStructured {
          content = try LeapJSONOutput.decode(output.value, maximumBytes: request.maxOutputBytes)
          for delta in try request.limits.boundedDeltas(for: content) {
            continuation.yield(.textDelta(delta))
          }
        } else { content = output.value }
        continuation.yield(.completed(ModelTurn(content: content, stopReason: .stop)))
        continuation.finish()
      } catch { continuation.finish(throwing: Self.normalize(error)) }
    }
    continuation.onTermination = { _ in task.cancel() }
    return ModelClientInvocation(
      events: pair.stream,
      cancel: { task.cancel() },
      waitForCompletion: {
        _ = await task.result
        try await runtime.waitForNativeDrain()
      }
    )
  }

  private static func map(_ request: ModelRequest) throws -> (history: [LeapTextMessage], user: String) {
    try request.validateGenerationContract()
    try LeapTextGenerationPolicy.validate(request.outputFormat)
    guard request.tools.isEmpty,
      request.effectiveRequiredCapabilities.isSubset(of: supportedCapabilities),
      request.messages.allSatisfy({ $0.contentParts.allSatisfy { $0.modality == .text } })
    else { throw LeapError.unsupportedLanguageOrCapability }
    guard let current = request.messages.last, current.role == .user, !current.content.isEmpty else {
      throw LeapError.invalidRequest
    }
    let history = try request.messages.dropLast().map { message -> LeapTextMessage in
      let role: LeapTextRole
      switch message.role {
      case .system: role = .system
      case .user: role = .user
      case .assistant: role = .assistant
      case .tool: throw LeapError.unsupportedLanguageOrCapability
      }
      return LeapTextMessage(role: role, content: message.content)
    }
    return (history, current.content)
  }

  private static func normalize(_ error: any Error) -> ModelGenerationFailure {
    if let error = error as? ModelGenerationFailure { return error }
    if error is CancellationError {
      return ModelGenerationFailure(.cancelled, "Model generation was cancelled.")
    }
    guard let error = error as? LeapError else {
      return ModelGenerationFailure(.transportFailure, "LEAP text generation failed.")
    }
    switch error {
    case .invalidRequest:
      return ModelGenerationFailure(.invalidRequest, error.localizedDescription)
    case .unsupportedLanguageOrCapability:
      return ModelGenerationFailure(.policyViolation, error.localizedDescription)
    case .modelMissing, .busy, .invalidArtifact:
      return ModelGenerationFailure(.sourceUnavailable, error.localizedDescription)
    case .insufficientDisk, .outputLimitExceeded:
      return ModelGenerationFailure(.limitExceeded, error.localizedDescription)
    case .invalidRuntimeOutput:
      return ModelGenerationFailure(.malformedEvent, error.localizedDescription)
    case .generationTimedOut, .generationStalled:
      return ModelGenerationFailure(.deadlineExceeded, error.localizedDescription)
    case .generationInterrupted, .nativeFailure:
      return ModelGenerationFailure(.transportFailure, "LEAP text generation failed.")
    }
  }
}

final class LeapTextOutputAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  private var storedFailure: (any Error)?

  func append(_ value: String, maximumBytes: Int) throws {
    lock.lock()
    defer { lock.unlock() }
    if let storedFailure { throw storedFailure }
    let valueBytes = Data(value.utf8)
    let (count, overflow) = bytes.count.addingReportingOverflow(valueBytes.count)
    guard !overflow, count <= maximumBytes else {
      throw ModelGenerationFailure(.limitExceeded, "LEAP text output exceeds the byte limit.")
    }
    bytes.append(valueBytes)
  }

  func fail(_ error: any Error) {
    lock.lock()
    if storedFailure == nil { storedFailure = error }
    lock.unlock()
  }

  var failure: (any Error)? {
    lock.lock()
    defer { lock.unlock() }
    return storedFailure
  }

  var value: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: bytes, as: UTF8.self)
  }
}
