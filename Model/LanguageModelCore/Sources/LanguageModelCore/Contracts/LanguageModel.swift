import Foundation

/// A lightweight, immutable model description. The descriptor is the single
/// capability authority; this protocol never owns a transcript or an Agent.
public protocol LanguageModel: Sendable {
  associatedtype Executor: LanguageModelExecutor where Executor.Model == Self
  var descriptor: ModelDescriptor { get }
  var executorConfiguration: Executor.Configuration { get }
}

extension LanguageModel {
  public var capabilities: ModelCapabilities { descriptor.capabilities }
}

/// Inference mechanism, independent of session admission and Agent effects.
/// Initializers must not start inference or create unowned producer tasks.
/// `respond` must join all producer/native work before returning or throwing.
/// Throw `ModelExecutorDrainFailure` when that settlement cannot be proved.
public protocol LanguageModelExecutor: Sendable {
  associatedtype Model: LanguageModel where Model.Executor == Self
  associatedtype Configuration: Hashable & Sendable

  init(configuration: Configuration) throws
  func shutdown() async throws
  func prewarm(model: Model, transcript: [AgentMessage]) async throws
  func respond(
    to request: ModelRequest,
    model: Model,
    streamingInto channel: ModelGenerationChannel
  ) async throws
}

extension LanguageModelExecutor {
  /// Executors without owned resources (including borrowed client bindings) need no teardown.
  public func shutdown() async throws {}

  /// No speculative work by default. A provider may opt into actual prewarming.
  public func prewarm(model: Model, transcript: [AgentMessage]) async throws {
    try Task.checkCancellation()
  }
}

/// Invocation-scoped output port. Failure is the throwing boundary, not a
/// second `.failed` event; existing serialized request/turn contracts survive.
public struct ModelGenerationChannel: Sendable {
  private let publish: @Sendable (ModelEvent) throws -> Void
  private let effectStarted: @Sendable () -> Void

  public init(
    publish: @escaping @Sendable (ModelEvent) throws -> Void,
    onStarted: @escaping @Sendable () -> Void
  ) {
    self.publish = publish
    self.effectStarted = onStarted
  }

  public func send(_ event: ModelEvent) throws {
    if case .started = event { effectStarted() }
    try publish(event)
  }

  /// Signal immediately before native I/O, even if its buffered started event
  /// has not reached the consumer. Never call for validation or preparation.
  public func markProviderEffectStarted() { effectStarted() }
}

public struct ModelExecutorDrainFailure: ModelClientFailure, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let message: String
  private let retainedOwner: (any Sendable)?

  public init(_ message: String) {
    self.message = ModelGenerationFailure(.transportFailure, message).message
    retainedOwner = nil
  }

  /// Retain the exact invocation or upstream receipt when native settlement is
  /// unproved. The owner is never exposed as diagnostic or serialized output.
  public init(_ message: String, retaining owner: any Sendable) {
    self.message = ModelGenerationFailure(.transportFailure, message).message
    retainedOwner = owner
  }

  public var description: String { message }
  public var debugDescription: String { message }
  public var errorDescription: String? { message }
  public var modelFailureCode: String { "nativeDrainFailed" }
  public var modelFailureDetails: [String: JSONValue] { [:] }
}
