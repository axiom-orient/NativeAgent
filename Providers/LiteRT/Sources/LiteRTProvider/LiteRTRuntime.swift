import Foundation
import LiteRTNative
import ModelArtifactStore
import LanguageModelCore
import LanguageModelRuntime

#if os(iOS) || os(macOS)
  import CLiteRTLM
#endif

public enum LiteRTProvider {
  public static let providerID = "litert-lm.text"
  public static let upstreamVersion = LiteRTNativeRuntime.version
  public static let capabilities: ModelCapabilities = [
    .textInput, .textOutput, .toolCalls, .structuredOutput,
  ]

  static func modelDescriptor(for model: LiteRTTextModel) -> ModelDescriptor {
    ModelDescriptor(
      id: model.id,
      providerID: providerID,
      displayName: model.displayName,
      capabilities: model.capabilities,
      contextWindowTokens: model.contextWindowTokens)
  }

  /// Loads one already-present `.litertlm` artifact and returns its sole
  /// lifecycle authority. No network, discovery, fallback, or model routing is
  /// performed here.
  public static func loadRuntime(
    _ model: LiteRTTextModel,
    runtimeID: ModelRuntimeID? = nil,
    policy: ModelRuntimePolicy = .default
  ) async throws -> ModelRuntime {
    try await loadRuntime(model, runtimeID: runtimeID, policy: policy, artifactLease: nil)
  }

  static func loadRuntime(
    _ model: LiteRTTextModel,
    runtimeID: ModelRuntimeID? = nil,
    policy: ModelRuntimePolicy = .default,
    artifactLease: ArtifactLease?
  ) async throws -> ModelRuntime {
    var transferredLease = false
    defer {
      if !transferredLease { artifactLease?.close() }
    }
    try Task.checkCancellation()
    #if os(iOS) || os(macOS)
      guard FileManager.default.fileExists(atPath: model.modelURL.path) else {
        throw ModelGenerationFailure(.sourceUnavailable, "The selected LiteRT-LM model is missing.")
      }
      if let cache = model.cacheDirectoryURL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cache.path, isDirectory: &isDirectory),
          isDirectory.boolValue
        else {
          throw ModelGenerationFailure(
            .invalidRequest,
            "The selected LiteRT-LM cache directory does not exist."
          )
        }
      }

      let resource = try await Task.detached(priority: .userInitiated) {
        try LiteRTNativeEngine(model: model)
      }.value
      let descriptor = Self.modelDescriptor(for: model)
      let client = LiteRTModelClient(
        resource: resource,
        descriptor: descriptor
      )
      let runtime: ModelRuntime
      do {
        // Detached native construction is joined above. A cancelled caller must
        // release that resource and its lease, never receive a live runtime.
        try Task.checkCancellation()
        runtime = try ModelRuntime(
          id: runtimeID ?? ModelRuntimeID(rawValue: "litert-lm.\(model.id)"),
          client: client,
          descriptor: descriptor,
          policy: policy,
          cleanup: {
            resource.shutdown()
            artifactLease?.close()
          })
      } catch {
        resource.shutdown()
        throw error
      }
      transferredLease = true
      return runtime
    #else
      throw ModelGenerationFailure(
        .sourceUnavailable,
        "LiteRT-LM is supported only on iOS and macOS."
      )
    #endif
  }
}

#if os(iOS) || os(macOS)
  private struct LiteRTModelClient: ModelClient, Sendable {
    let providerID = LiteRTProvider.providerID
    let modelDescriptor: ModelDescriptor?
    private let resource: LiteRTNativeEngine

    init(resource: LiteRTNativeEngine, descriptor: ModelDescriptor) {
      self.resource = resource
      self.modelDescriptor = descriptor
    }

    func generate(request: ModelRequest) async throws -> ModelTurn {
      try validate(request)
      return try await generateValidated(request)
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
      let state = StreamState(client: self, request: request)
      // Unfolding awaits native generation in the consumer task. Cancellation
      // cannot report EOF while a detached stream producer still uses the engine.
      return AsyncThrowingStream(unfolding: { try await state.next() })
    }

    private actor StreamState {
      let client: LiteRTModelClient
      let request: ModelRequest
      var phase = 0
      init(client: LiteRTModelClient, request: ModelRequest) {
        self.client = client; self.request = request
      }
      func next() async throws -> ModelEvent? {
        try Task.checkCancellation()
        switch phase {
        case 0:
          try client.validate(request)
          phase = 1
          return .started(descriptor: client.modelDescriptor)
        case 1:
          phase = 2
          return .completed(try await client.generateValidated(request))
        default: return nil
        }
      }
    }

    private func validate(_ request: ModelRequest) throws {
      guard let descriptor = modelDescriptor else {
        throw ModelGenerationFailure(.sourceUnavailable, "LiteRT-LM descriptor is unavailable.")
      }
      try request.validateGenerationContract()
      try request.validateSupportedCapabilities(descriptor.capabilities)
      try Self.validateProviderContract(request)
    }

    private func generateValidated(_ request: ModelRequest) async throws -> ModelTurn {
      let cancellation = LiteRTGenerationCancellation()
      let worker = Task.detached(priority: .userInitiated) {
        try resource.generate(request: request, cancellation: cancellation)
      }
      return try await withTaskCancellationHandler {
        // Cancellation leaves native model state unqualified for reuse. Wait
        // for the worker first, then invalidate this engine; hosts reload
        // explicitly rather than receiving a hidden retry or stale state.
        defer { if cancellation.isCancelled { resource.shutdown() } }
        do {
          return try await worker.value
        } catch is CancellationError {
          throw CancellationError()
        } catch let failure as ModelGenerationFailure {
          throw failure
        } catch let failure as any ModelClientFailure {
          throw failure
        } catch {
          throw ModelGenerationFailure(.sourceUnavailable, "LiteRT-LM generation failed.")
        }
      } onCancel: {
        cancellation.cancel()
        worker.cancel()
      }
    }

    private static func validateProviderContract(_ request: ModelRequest) throws {
      guard !request.containsNonTextContent else {
        throw ModelGenerationFailure(
          .policyViolation, "LiteRT-LM text does not accept media input.")
      }
      let systemCount = request.messages.filter { $0.role == .system }.count
      guard systemCount <= 1 else {
        throw ModelGenerationFailure(
          .invalidRequest,
          "LiteRT-LM accepts at most one system message per model invocation."
        )
      }
      if !request.tools.isEmpty, case .jsonObject = request.outputFormat {
        throw ModelGenerationFailure(
          .invalidRequest,
          "LiteRT-LM tool calling and constrained JSON output are separate invocation modes."
        )
      }
      for message in request.messages where message.role == .tool {
        guard message.toolCallID != nil, message.toolName != nil else {
          throw ModelGenerationFailure(
            .invalidRequest,
            "LiteRT-LM tool-result messages require a tool call identifier and name."
          )
        }
      }
      guard let current = request.messages.last(where: { $0.role != .system }),
        current.role == .user || current.role == .tool
      else {
        throw ModelGenerationFailure(
          .invalidRequest,
          "LiteRT-LM generation requires a final user or tool-result message."
        )
      }
    }
  }

  private final class LiteRTGenerationCancellation: @unchecked Sendable {
    private let condition = NSCondition()
    private var conversation: OpaquePointer?
    private var cancelled = false
    private var activeNativeCancelCalls = 0

    /// Publishes the native handle. If cancellation won the race, native cancel
    /// runs outside the Swift lock while `dispose` keeps the handle alive.
    func install(_ conversation: OpaquePointer) {
      condition.lock()
      self.conversation = conversation
      let shouldCancel = cancelled
      if shouldCancel { activeNativeCancelCalls += 1 }
      condition.unlock()
      if shouldCancel {
        litert_lm_conversation_cancel_process(conversation)
        finishNativeCancelCall()
      }
    }

    /// Unpublishes the handle and waits for every native cancel call which
    /// already borrowed it before deleting the conversation.
    func dispose(_ conversation: OpaquePointer) {
      condition.lock()
      if self.conversation == conversation { self.conversation = nil }
      while activeNativeCancelCalls > 0 { condition.wait() }
      condition.unlock()
      litert_lm_conversation_delete(conversation)
    }

    func cancel() {
      condition.lock()
      cancelled = true
      guard let conversation else {
        condition.unlock()
        return
      }
      activeNativeCancelCalls += 1
      condition.unlock()
      litert_lm_conversation_cancel_process(conversation)
      finishNativeCancelCall()
    }

    var isCancelled: Bool {
      condition.lock()
      defer { condition.unlock() }
      return cancelled
    }

    private func finishNativeCancelCall() {
      condition.lock()
      activeNativeCancelCalls -= 1
      if activeNativeCancelCalls == 0 { condition.broadcast() }
      condition.unlock()
    }
  }

  private final class LiteRTNativeEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let model: LiteRTTextModel
    private var engine: OpaquePointer?

    init(model: LiteRTTextModel) throws {
      self.model = model
      guard
        let settings = litert_lm_engine_settings_create(
          model.modelURL.path,
          model.backend.rawValue,
          nil,
          nil
        )
      else {
        throw LiteRTProviderFailure(
          code: "engineSettingsCreateFailed",
          message: "LiteRT-LM could not create engine settings."
        )
      }
      defer { litert_lm_engine_settings_delete(settings) }

      if let contextWindowTokens = model.contextWindowTokens {
        guard contextWindowTokens <= Int(Int32.max) else {
          throw ModelGenerationFailure(
            .invalidRequest,
            "LiteRT-LM context window exceeds the native integer range."
          )
        }
        litert_lm_engine_settings_set_max_num_tokens(settings, Int32(contextWindowTokens))
      }
      if let cacheDirectoryURL = model.cacheDirectoryURL {
        litert_lm_engine_settings_set_cache_dir(settings, cacheDirectoryURL.path)
      }

      guard let engine = litert_lm_engine_create(settings) else {
        throw LiteRTProviderFailure(
          code: "engineCreateFailed",
          message: "LiteRT-LM could not load the selected model."
        )
      }
      self.engine = engine
    }

    deinit {
      if let engine { litert_lm_engine_delete(engine) }
    }

    func shutdown() {
      lock.lock()
      let handle = engine
      engine = nil
      lock.unlock()
      if let handle { litert_lm_engine_delete(handle) }
    }

    func generate(
      request: ModelRequest,
      cancellation: LiteRTGenerationCancellation
    ) throws -> ModelTurn {
      if cancellation.isCancelled { throw CancellationError() }
      let engineHandle: OpaquePointer
      lock.lock()
      guard let existing = engine else {
        lock.unlock()
        throw ModelGenerationFailure(.sourceUnavailable, "LiteRT-LM runtime is closed. Load a new runtime after cancellation or shutdown.")
      }
      engineHandle = existing
      lock.unlock()

      let rendered = try LiteRTRequestRenderer.render(request)
      guard let sessionConfig = litert_lm_session_config_create() else {
        throw LiteRTProviderFailure(
          code: "sessionConfigCreateFailed",
          message: "LiteRT-LM could not create a session configuration."
        )
      }
      defer { litert_lm_session_config_delete(sessionConfig) }
      let sampler = model.sampling == .greedy
        ? litert_lm_sampler_params_create(kLiteRtLmSamplerTypeTopP) : nil
      defer { if let sampler { litert_lm_sampler_params_delete(sampler) } }
      if model.sampling == .greedy {
        guard let sampler else {
          throw LiteRTProviderFailure(code: "samplerCreateFailed", message: "LiteRT-LM could not create the requested greedy sampler.")
        }
        // TOP_P with top-k=1 leaves one maximum-logit token; p=1 and
        // temperature=1 preserve the explicit greedy sampling contract.
        litert_lm_sampler_params_set_top_k(sampler, 1)
        litert_lm_sampler_params_set_top_p(sampler, 1)
        litert_lm_sampler_params_set_temperature(sampler, 1)
        litert_lm_session_config_set_sampler_params(sessionConfig, sampler)
      }


      guard let conversationConfig = litert_lm_conversation_config_create() else {
        throw LiteRTProviderFailure(
          code: "conversationConfigCreateFailed",
          message: "LiteRT-LM could not create a conversation configuration."
        )
      }
      defer { litert_lm_conversation_config_delete(conversationConfig) }
      litert_lm_conversation_config_set_session_config(conversationConfig, sessionConfig)

      if let systemContents = rendered.systemContents {
        litert_lm_conversation_config_set_system_message(conversationConfig, systemContents)
      }
      if let initialMessages = rendered.initialMessages {
        litert_lm_conversation_config_set_messages(conversationConfig, initialMessages)
      }
      if let tools = rendered.tools {
        litert_lm_conversation_config_set_tools(conversationConfig, tools)
      }
      if rendered.outputSchema != nil {
        var provider = kLiteRtLmConstraintProviderTypeLlGuidance
        litert_lm_conversation_config_set_constraint_provider(conversationConfig, &provider)
        litert_lm_conversation_config_set_enable_constrained_decoding(conversationConfig, true)
      }

      guard let conversation = litert_lm_conversation_create(engineHandle, conversationConfig)
      else {
        throw LiteRTProviderFailure(
          code: "conversationCreateFailed",
          message: "LiteRT-LM could not create a conversation."
        )
      }
      cancellation.install(conversation)
      defer { cancellation.dispose(conversation) }
      if cancellation.isCancelled { throw CancellationError() }

      guard let optionalArgs = litert_lm_conversation_optional_args_create() else {
        throw LiteRTProviderFailure(
          code: "optionalArgsCreateFailed",
          message: "LiteRT-LM could not create generation arguments."
        )
      }
      defer { litert_lm_conversation_optional_args_delete(optionalArgs) }
      if let outputSchema = rendered.outputSchema {
        litert_lm_conversation_optional_args_set_constraint(
          optionalArgs,
          kLiteRtLmConstraintTypeJsonSchema,
          outputSchema
        )
      }

      guard
        let response = litert_lm_conversation_send_message(
          conversation,
          rendered.currentMessage,
          nil,
          optionalArgs
        )
      else {
        if cancellation.isCancelled { throw CancellationError() }
        throw LiteRTProviderFailure(
          code: "generationFailed",
          message: "LiteRT-LM returned no generation result."
        )
      }
      defer { litert_lm_json_response_delete(response) }
      if cancellation.isCancelled { throw CancellationError() }
      guard let raw = litert_lm_json_response_get_string(response) else {
        throw LiteRTProviderFailure(
          code: "responseDecodeFailed",
          message: "LiteRT-LM returned an unreadable response."
        )
      }
      return try LiteRTResponseParser.parse(String(cString: raw))
    }
  }

#endif

struct LiteRTRenderedRequest {
  let systemContents: String?
  let initialMessages: String?
  let currentMessage: String
  let tools: String?
  let outputSchema: String?
}

enum LiteRTRequestRenderer {
  static func render(_ request: ModelRequest) throws -> LiteRTRenderedRequest {
    let system = request.messages.first(where: { $0.role == .system })
    let conversation = request.messages.filter { $0.role != .system }
    guard let current = conversation.last else {
      throw ModelGenerationFailure(.invalidRequest, "LiteRT-LM requires a model input message.")
    }

    let initial = Array(conversation.dropLast())
    return LiteRTRenderedRequest(
      systemContents: try system.map { try jsonString(textContents($0.content)) },
      initialMessages: initial.isEmpty ? nil : try jsonString(initial.map(messageJSON)),
      currentMessage: try jsonString(messageJSON(current)),
      tools: request.tools.isEmpty ? nil : try jsonString(request.tools.map(toolJSON)),
      outputSchema: try outputSchema(request.outputFormat)
    )
  }

  private static func messageJSON(_ message: AgentMessage) throws -> [String: Any] {
    switch message.role {
    case .system:
      throw ModelGenerationFailure(
        .invalidRequest, "System messages must use LiteRT-LM system configuration.")
    case .user:
      return ["role": "user", "content": textContents(message.content)]
    case .assistant:
      var value: [String: Any] = ["role": "model"]
      if !message.content.isEmpty { value["content"] = textContents(message.content) }
      if !message.toolCalls.isEmpty {
        value["tool_calls"] = try message.toolCalls.map(toolCallJSON)
      }
      return value
    case .tool:
      guard let name = message.toolName, let id = message.toolCallID else {
        throw ModelGenerationFailure(.invalidRequest, "LiteRT-LM tool result is incomplete.")
      }
      return [
        "role": "tool",
        "content": [
          [
            "type": "tool_response",
            "name": name,
            "id": id,
            "response": try message.modelVisibleContent(),
          ]
        ],
      ]
    }
  }

  private static func textContents(_ value: String) -> [[String: Any]] {
    [["type": "text", "text": value]]
  }

  private static func toolJSON(_ tool: ModelTool) throws -> [String: Any] {
    guard let parameters = try foundationObject(tool.inputSchema) as? [String: Any] else {
      throw ModelGenerationFailure(.invalidRequest, "LiteRT-LM tool schema must be an object.")
    }
    return [
      "type": "function",
      "function": [
        "name": tool.name,
        "description": tool.description,
        "parameters": parameters,
      ],
    ]
  }

  private static func toolCallJSON(_ call: ToolCall) throws -> [String: Any] {
    guard let arguments = try foundationObject(call.arguments) as? [String: Any] else {
      throw ModelGenerationFailure(
        .invalidRequest, "LiteRT-LM tool call arguments must be an object.")
    }
    return [
      "id": call.id,
      "type": "function",
      "function": ["name": call.name, "arguments": arguments],
    ]
  }

  private static func outputSchema(_ format: ModelOutputFormat) throws -> String? {
    guard case .jsonObject(let schema) = format else { return nil }
    return try jsonString(try foundationObject(schema))
  }

  private static func foundationObject(_ value: JSONValue) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data)
  }

  private static func jsonString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let value = String(data: data, encoding: .utf8) else {
      throw ModelGenerationFailure(
        .invalidRequest, "LiteRT-LM request could not be encoded as UTF-8 JSON.")
    }
    return value
  }
}

enum LiteRTResponseParser {
  static func parse(_ value: String) throws -> ModelTurn {
    guard let data = value.data(using: .utf8),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ModelGenerationFailure(.malformedEvent, "LiteRT-LM response is not a JSON object.")
    }
    let role = root["role"] as? String
    guard role == nil || role == "model" || role == "assistant" else {
      throw ModelGenerationFailure(.malformedEvent, "LiteRT-LM returned a non-model response role.")
    }

    var text = ""
    if let content = root["content"] as? [[String: Any]] {
      for part in content {
        guard let type = part["type"] as? String else { continue }
        guard type == "text" else {
          throw ModelGenerationFailure(
            .malformedEvent, "LiteRT-LM returned unsupported non-text output.")
        }
        guard let value = part["text"] as? String else {
          throw ModelGenerationFailure(.malformedEvent, "LiteRT-LM returned malformed text output.")
        }
        text.append(value)
      }
    }

    var calls: [ToolCall] = []
    if let toolCalls = root["tool_calls"] as? [[String: Any]] {
      for item in toolCalls {
        guard let id = item["id"] as? String,
          let function = item["function"] as? [String: Any],
          let name = function["name"] as? String,
          let arguments = function["arguments"] as? [String: Any],
          let jsonArguments = JSONValue.from(any: arguments)
        else {
          throw ModelGenerationFailure(.malformedEvent, "LiteRT-LM returned a malformed tool call.")
        }
        calls.append(ToolCall(id: id, name: name, arguments: jsonArguments))
      }
    }

    guard !text.isEmpty || !calls.isEmpty else {
      throw ModelGenerationFailure(.malformedEvent, "LiteRT-LM returned no text or tool call.")
    }
    return ModelTurn(
      content: text,
      toolCalls: calls,
      metadata: ["litertLMVersion": .string(LiteRTProvider.upstreamVersion)],
      stopReason: calls.isEmpty ? .stop : .toolUse
    )
  }
}

private struct LiteRTProviderFailure: ModelClientFailure, Sendable {
  let code: String
  let message: String

  var errorDescription: String? { message }
  var modelFailureCode: String { "litert.\(code)" }
  var modelFailureDetails: [String: JSONValue] {
    ["upstreamVersion": .string(LiteRTProvider.upstreamVersion)]
  }
}
