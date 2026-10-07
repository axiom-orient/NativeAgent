import EmbeddingCore
import Foundation

public enum LiteRTEmbeddingStatus: Sendable, Equatable {
  case ready, running, closing, closed, failed
}

/// Sole admission/cancellation/drain/release owner for one native embedding
/// engine. No text generation, remote I/O, queue of requests or fallback.
public actor LiteRTEmbeddingModel: EmbeddingModel {
  public nonisolated let profile: EmbeddingProfile
  private let compute: @Sendable (String) async throws -> [Float]
  private let close: @Sendable () async throws -> Void
  private var phase: LiteRTEmbeddingStatus = .ready
  private var active: Task<EmbeddingVector, any Error>?
  private var activeID: UUID?
  private var closing: Task<Void, any Error>?

  init(
    profile: EmbeddingProfile = EmbeddingGemma2.profile,
    compute: @escaping @Sendable (String) async throws -> [Float],
    close: @escaping @Sendable () async throws -> Void
  ) {
    self.profile = profile
    self.compute = compute
    self.close = close
  }

  /// Opens an already-present, immutable generic `.litertlm` file. The host
  /// keeps that file intact until shutdown. This does not download any model.
  public static func load(modelURL: URL, cacheDirectory: URL) async throws -> LiteRTEmbeddingModel {
    try Task.checkCancellation()
    guard modelURL.isFileURL, cacheDirectory.isFileURL,
      !modelURL.path.contains("\0"), !cacheDirectory.path.contains("\0")
    else { throw EmbeddingFailure.invalidInput }
    #if canImport(CLiteRTLM) || canImport(CLiteRTLM_mac)
      let resident = NativeEmbeddingResident()
      do {
        try await resident.load(modelURL: modelURL, cacheDirectory: cacheDirectory)
        try Task.checkCancellation()
      } catch {
        await resident.close()
        throw error
      }
      return LiteRTEmbeddingModel(
        compute: { try await resident.compute($0) },
        close: { await resident.close() }
      )
    #else
      throw EmbeddingFailure.unsupportedHost
    #endif
  }

  public func status() -> LiteRTEmbeddingStatus { phase }

  public func embed(_ input: EmbeddingInput) async throws -> EmbeddingVector {
    try Task.checkCancellation()
    guard phase == .ready else {
      throw phase == .running ? EmbeddingFailure.busy : EmbeddingFailure.closed
    }
    let text = try EmbeddingGemma2.formattedText(for: input)
    let compute = self.compute
    let profile = self.profile
    let id = UUID()
    let worker = Task {
      try Task.checkCancellation()
      let values = try await compute(text)
      try Task.checkCancellation()
      return try EmbeddingVector(nativeValues: values, profile: profile)
    }
    active = worker
    activeID = id
    phase = .running
    defer {
      if activeID == id {
        active = nil
        activeID = nil
        if phase == .running { phase = .ready }
      }
    }
    // C has no embedding cancel API. Logical cancellation discards the output
    // only AFTER the synchronous native call returns and its buffers are freed.
    let output = try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
    try Task.checkCancellation()
    guard phase == .running else { throw EmbeddingFailure.closed }
    return output
  }

  /// Concurrent/cancelled callers join the same teardown. Intake closes before
  /// cancellation; native completion precedes delete. Close failure is sticky.
  public func shutdown() async throws {
    if phase == .closed { return }
    let task: Task<Void, any Error>
    if let closing {
      task = closing
    } else {
      phase = .closing
      let worker = active
      let close = self.close
      task = Task {
        worker?.cancel()
        if let worker { _ = await worker.result }
        try await close()
      }
      closing = task
    }
    do {
      try await task.value
      phase = .closed
    } catch {
      phase = .failed
      throw error
    }
  }
}
