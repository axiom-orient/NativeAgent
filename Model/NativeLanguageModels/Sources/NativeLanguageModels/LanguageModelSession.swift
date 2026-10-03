import LanguageModelCore
import LanguageModelRuntime

/// Source-shape convenience, NOT FoundationModels drop-in compatibility.
/// No sampling knob is exposed unless the core request can enforce it.
public struct GenerationOptions: Sendable {
  public var tools: [ModelTool]
  public var outputFormat: ModelOutputFormat
  public var maxOutputBytes: Int?
  public var deadline: Duration?
  public var limits: ModelGenerationLimits

  public init(
    tools: [ModelTool] = [], outputFormat: ModelOutputFormat = .text,
    maxOutputBytes: Int? = nil, deadline: Duration? = nil,
    limits: ModelGenerationLimits = .default
  ) {
    self.tools = tools
    self.outputFormat = outputFormat
    self.maxOutputBytes = maxOutputBytes
    self.deadline = deadline
    self.limits = limits
  }
}

/// The complete façade is one immutable projection of the runtime conversation.
/// Tool calls are returned, never executed. The Agent/host owns effect approval.
public struct LanguageModelSession: Sendable {
  private let session: ModelSession

  public init(id: String, runtime: ModelRuntimeAccess, instructions: String? = nil) {
    session = ModelSession(
      id: id, runtime: runtime,
      transcript: instructions.map { [.init(role: .system, content: $0)] } ?? [])
  }

  public init<Model: LanguageModel>(
    id: String, model: Model,
    executorStore: ModelExecutorStore, instructions: String? = nil
  ) async throws {
    self.init(
      id: id, runtime: .borrowed(try await executorStore.runtime(for: model)),
      instructions: instructions)
  }

  public var transcript: [AgentMessage] { get async { await session.transcript } }
  public var status: ModelSession.Status { get async { await session.status } }

  public func respond(to prompt: String, options: GenerationOptions = .init()) async throws
    -> ModelTurn
  {
    try await respond(to: [.init(role: .user, content: prompt)], options: options)
  }

  /// Accepts explicit tool-result/history messages without inventing an effect executor.
  public func respond(to messages: [AgentMessage], options: GenerationOptions = .init())
    async throws -> ModelTurn
  {
    try await session.respond(
      to: messages, tools: options.tools, outputFormat: options.outputFormat,
      maxOutputBytes: options.maxOutputBytes, deadline: options.deadline, limits: options.limits)
  }

  public func streamResponse(to prompt: String, options: GenerationOptions = .init()) async throws
    -> AsyncThrowingStream<ModelEvent, any Error>
  {
    try await session.stream(
      to: [.init(role: .user, content: prompt)], tools: options.tools,
      outputFormat: options.outputFormat, maxOutputBytes: options.maxOutputBytes,
      deadline: options.deadline, limits: options.limits)
  }

  public func cancel() async throws { try await session.cancel() }
  public func close() async throws { try await session.close() }
}
