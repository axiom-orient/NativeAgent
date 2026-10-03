@_spi(Service) import ChatGPTAccount
import LanguageModelCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// ChatGPT-account subscription adapter for the Codex Responses stream.
///
/// It never reads an API key, environment variable, or alternate provider. Authentication and
/// credential refresh are owned by `ChatGPTAccountSession`; model discovery by `ChatGPTTextSession`; failure never selects a fallback.
public struct ChatGPTModelClient: ModelClientWithOwnedInvocation, Sendable {
  public static let minimumResponseBytes = 64 * 1_024
  public static let defaultMaximumResponseBytes = 8 * 1_024 * 1_024
  public static let supportedMaximumResponseBytes = 16 * 1_024 * 1_024
  public static let maximumResponseIDUTF8Bytes = 4_096

  public let providerID: String
  public let modelDescriptor: ModelDescriptor?
  private let text: ChatGPTTextSession
  private var account: ChatGPTAccountSession { text.account }
  private let model: ChatGPTModelSelection
  private let transport: any ChatGPTTransport
  private let maxResponseBytes: Int

  public init(
    account: ChatGPTAccountSession,
    model: ChatGPTModelSelection = .recommended,
    transport: any ChatGPTTransport = URLSessionChatGPTTransport(),
    maxResponseBytes: Int = Self.defaultMaximumResponseBytes,
    providerID: String = "chatgpt.subscription",
    modelDescriptor: ModelDescriptor? = nil
  ) throws {
    try self.init(
      text: ChatGPTTextSession(account: account), model: model, transport: transport,
      maxResponseBytes: maxResponseBytes, providerID: providerID,
      modelDescriptor: modelDescriptor)
  }

  public init(
    text: ChatGPTTextSession,
    model: ChatGPTModelSelection = .recommended,
    transport: any ChatGPTTransport = URLSessionChatGPTTransport(),
    maxResponseBytes: Int = Self.defaultMaximumResponseBytes,
    providerID: String = "chatgpt.subscription",
    modelDescriptor: ModelDescriptor? = nil
  ) throws {
    guard (Self.minimumResponseBytes...Self.supportedMaximumResponseBytes).contains(maxResponseBytes) else {
      throw ModelGenerationFailure(
        .limitExceeded, "Provider response limit is outside the supported bounds.")
    }
    if case .exact(let identifier) = model { try chatGPTValidateModel(identifier) }
    self.text = text
    self.model = model
    self.transport = transport
    self.maxResponseBytes = maxResponseBytes
    self.providerID = providerID
    self.modelDescriptor = modelDescriptor
  }

  public func generate(request: ModelRequest) async throws -> ModelTurn {
    let operation = invocation(request: request, onStarted: {})
    return try await withTaskCancellationHandler {
      do {
        let turn = try await ModelStreamContract.completedTurn(from: operation.events, request: request)
        try await operation.waitForCompletion()
        try Task.checkCancellation()
        return turn
      } catch {
        try await operation.cancelAndDrain()
        throw error
      }
    } onCancel: {
      operation.cancel()
    }
  }

  public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
    invocation(request: request, onStarted: {}).events
  }

  public func invocation(
    request: ModelRequest,
    onStarted: @escaping @Sendable () -> Void
  ) -> ModelClientInvocation {
    let (events, continuation) = AsyncThrowingStream<ModelEvent, any Error>.makeStream()
    let producer = Task {
      do {
        try Self.validate(request)
        try Task.checkCancellation()
        // Independent of the buffered event: cancelled consumers cannot erase the
        // provider-effect boundary after credential/catalog/network work begins.
        onStarted()
        if case .terminated = continuation.yield(.started(descriptor: modelDescriptor)) {
          throw CancellationError()
        }
        var authorization = try await account.requestAuthorization()
        let initialAuthorization = authorization
        let modelID = try await text.modelID(for: model)
        let profile = await account.protocolProfile()
        for attempt in 0..<ChatGPTSubscriptionRetryPolicy.authenticationAttemptCount {
          var urlRequest = URLRequest(url: profile.responsesEndpoint)
          urlRequest.httpMethod = "POST"
          try Task.checkCancellation()
          try await account.validateAuthorization(initialAuthorization)
          try authorization.apply(to: &urlRequest)
          urlRequest.setValue(profile.clientVersion, forHTTPHeaderField: "Version")
          urlRequest.setValue(chatGPTUserAgent(profile: profile), forHTTPHeaderField: "User-Agent")
          urlRequest.setValue(profile.originator, forHTTPHeaderField: "Originator")
          urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
          urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          urlRequest.httpBody = try Self.body(model: modelID, request: request)

          do {
            let operation = chatGPTSSE(
              transport: transport, request: urlRequest,
              maxResponseBytes: maxResponseBytes, maxFrameBytes: request.limits.maxFrameBytes)
            try await withTaskCancellationHandler {
              do {
                var decoder = Decoder(request: request)
                for try await event in operation.events {
                  try Task.checkCancellation()
                  for output in try decoder.consume(event) {
                    if case .terminated = continuation.yield(output) { throw CancellationError() }
                  }
                }
                try await operation.waitForCompletion()
                try Task.checkCancellation()
                try decoder.finish()
              } catch {
                operation.cancel()
                try await operation.waitForCompletion()
                throw error
              }
            } onCancel: {
              operation.cancel()
            }
            continuation.finish()
            return
          } catch ChatGPTWireError.httpStatus(401)
            where ChatGPTSubscriptionRetryPolicy.permitsAuthenticationRefresh(after: attempt)
          {
            // The previous attempt is drained before any refresh/re-dispatch.
            try Task.checkCancellation()
            try await account.validateAuthorization(initialAuthorization)
            authorization = try await account.requestAuthorization(forceRefresh: true)
            try await account.validateAuthorization(initialAuthorization)
          }
        }
        throw ChatGPTFailure(.signInRequired)
      } catch let error as ChatGPTTransportDrainFailure {
        // Auth/catalog work is owned by Account; its failed receipt is still a
        // producer drain failure, not an ordinary failed generation event.
        let failure = ModelExecutorDrainFailure(
          "ChatGPT account transport did not prove local completion.", retaining: error)
        continuation.finish(throwing: failure)
        throw failure
      } catch let failure as ModelExecutorDrainFailure {
        continuation.finish(throwing: failure)
        throw failure
      } catch {
        continuation.finish(throwing: Self.failure(error))
      }
    }
    continuation.onTermination = { termination in
      if case .cancelled = termination { producer.cancel() }
    }
    return ModelClientInvocation(
      events: events, cancel: { producer.cancel() },
      waitForCompletion: { try await producer.value })
  }

  private static func body(model: String, request: ModelRequest) throws -> Data {
    var object: [String: Any] = [
      "model": model,
      "input": try ChatGPTToolWireCodec.inputItems(for: request.messages),
      "stream": true,
      "store": false,
      "parallel_tool_calls": false,
      "include": ["reasoning.encrypted_content"],
      "reasoning": ["effort": "low"],
    ]
    if !request.tools.isEmpty {
      object["tools"] = try ChatGPTToolWireCodec.tools(request.tools)
      object["tool_choice"] = "auto"
    }
    if let schema = try chatGPTOutputFields(request.outputFormat) {
      object["text"] = [
        "format": [
          "type": "json_schema",
          "name": "native_agent_output",
          "strict": true,
          "schema": schema,
        ]
      ]
    }
    return try chatGPTJSON(object)
  }

  private static func failure(_ error: any Error) -> ModelGenerationFailure {
    if let failure = error as? ChatGPTFailure {
      switch failure.code {
      case .signInRequired, .authorizationExpired, .tokenRefreshFailed:
        return ModelGenerationFailure(.authenticationRequired, "Sign in with ChatGPT is required.")
      case .rateLimited:
        return ModelGenerationFailure(
          .sourceUnavailable, "The ChatGPT subscription usage limit was reached.")
      case .invalidConfiguration, .modelUnavailable:
        return ModelGenerationFailure(.invalidRequest, failure.message)
      case .signInCancelled:
        return ModelGenerationFailure(.cancelled, "ChatGPT sign-in was cancelled.")
      case .authorizationFailed, .credentialStorageFailed, .tokenRefreshUnavailable,
        .transportFailure,
        .malformedResponse, .serviceRejected:
        return ModelGenerationFailure(.sourceUnavailable, "ChatGPT subscription transport failed.")
      }
    }
    if case ChatGPTWireError.httpStatus(let status) = error {
      if status == 429 {
        return ModelGenerationFailure(
          .sourceUnavailable, "The ChatGPT subscription usage limit was reached.")
      }
      if status == 401 || status == 403 {
        return ModelGenerationFailure(.authenticationRequired, "Sign in with ChatGPT is required.")
      }
    }
    return chatGPTFailure(error)
  }


  private struct Decoder: Sendable {
    let request: ModelRequest
    var outputBytes = 0
    var emittedBytes = Data()
    var terminal = false
    var refused = false
    var activeMessageID: String?
    var activeMessageStart = 0
    var addedMessageIDs: Set<String> = []
    var completedMessages: [String: Data] = [:]
    var completedToolCalls: [String: ToolCall] = [:]
    var toolCallOrder: [String] = []

    mutating func consume(_ event: ChatGPTSSEEvent) throws -> [ModelEvent] {
      if event.data == "[DONE]" { return [] }
      guard !terminal else { throw ChatGPTWireError.duplicateTerminal }
      guard !event.data.isEmpty else { return [] }
      let root = try chatGPTJSONObject(Data(event.data.utf8))
      guard let type = chatGPTString(root, "type") else {
        throw ChatGPTWireError.malformedSSE
      }
      switch type {
      case "response.output_text.delta":
        guard let delta = chatGPTString(root, "delta") else {
          throw ChatGPTWireError.malformedSSE
        }
        try beginImplicitMessageIfNeeded(itemID: chatGPTString(root, "item_id"))
        return try textDelta(delta)
      case "response.refusal.delta", "response.refusal.done":
        refused = true
        return []
      case "response.completed":
        let response = try responseObject(root)
        let (terminalEvents, terminalRefusal) = try reconcileTerminalOutput(response)
        let usage = try parseUsage(chatGPTObject(response, "usage"))
        let reason: ModelStopReason = refused || terminalRefusal
          ? .contentFilter
          : (completedToolCalls.isEmpty ? .stop : .toolUse)
        terminal = true
        return terminalEvents + completionEvents(reason: reason, usage: usage)
      case "response.incomplete":
        let response = try responseObject(root)
        let (terminalEvents, terminalRefusal) = try reconcileTerminalOutput(response)
        let reason = chatGPTObject(response, "incomplete_details").flatMap {
          chatGPTString($0, "reason")
        }
        let stop: ModelStopReason
        switch reason {
        case "max_output_tokens", "max_tokens": stop = .maxTokens
        case "content_filter": stop = .contentFilter
        case nil: stop = .other
        default: stop = .other
        }
        terminal = true
        return terminalEvents + completionEvents(
          reason: terminalRefusal ? .contentFilter : (completedToolCalls.isEmpty ? stop : .toolUse),
          usage: try parseUsage(chatGPTObject(response, "usage")))
      case "response.failed", "error":
        throw ChatGPTWireError.serviceFailure
      case "response.cancelled":
        throw CancellationError()
      case "response.output_item.added", "response.output_item.done":
        guard let item = chatGPTObject(root, "item") else {
          throw ChatGPTWireError.malformedSSE
        }
        let (events, itemRefused) = try processOutputItem(
          item, phase: type == "response.output_item.done" ? .done : .added)
        if itemRefused { refused = true }
        return events
      case "response.function_call_arguments.delta", "response.function_call_arguments.done":
        // Canonical function calls are admitted only from authoritative output_item.done/terminal items.
        return []
      case "response.custom_tool_call_input.delta", "response.custom_tool_call_input.done":
        throw ChatGPTWireError.policyViolation
      case "response.queued", "response.created", "response.in_progress",
        "response.metadata", "codex.response.metadata", "responsesapi.websocket_timing",
        "response.output_text.done", "response.output_text.annotation.added",
        "response.content_part.added", "response.content_part.done",
        "response.reasoning_text.delta", "response.reasoning_text.done",
        "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
        "response.reasoning_summary_part.added", "response.reasoning_summary_part.done":
        // Reasoning and lifecycle observations never become model output.
        return []
      default:
        throw ChatGPTWireError.unsupportedEvent
      }
    }

    mutating func finish() throws {
      guard terminal else { throw ChatGPTWireError.terminalMissing }
    }

    private func responseObject(_ root: [String: Any]) throws -> [String: Any] {
      guard let raw = root["response"] else { throw ChatGPTWireError.malformedSSE }
      guard let response = raw as? [String: Any] else { throw ChatGPTWireError.malformedSSE }
      guard let responseID = chatGPTString(response, "id"), !responseID.isEmpty,
        responseID.utf8.count <= ChatGPTModelClient.maximumResponseIDUTF8Bytes
      else { throw ChatGPTWireError.malformedSSE }
      return response
    }

    private mutating func reconcileTerminalOutput(_ response: [String: Any]) throws -> (
      [ModelEvent], Bool
    ) {
      guard let rawOutput = response["output"] else { return ([], false) }
      guard let output = rawOutput as? [Any] else { throw ChatGPTWireError.malformedSSE }
      var events: [ModelEvent] = []
      var refusal = false
      for rawItem in output {
        guard let item = rawItem as? [String: Any] else { throw ChatGPTWireError.malformedSSE }
        let (itemEvents, itemRefused) = try processOutputItem(item, phase: .terminal)
        events.append(contentsOf: itemEvents)
        if itemRefused { refusal = true }
      }
      return (events, refusal)
    }

    private enum ItemPhase { case added, done, terminal }

    private mutating func processOutputItem(
      _ item: [String: Any], phase: ItemPhase
    ) throws -> ([ModelEvent], Bool) {
      guard let itemType = chatGPTString(item, "type") else {
        throw ChatGPTWireError.malformedSSE
      }
      if itemType == "reasoning" { return ([], false) }
      if itemType == "function_call" {
        if phase == .added { return ([], false) }
        let call = try ChatGPTToolWireCodec.canonicalCall(
          ChatGPTToolWireCodec.functionCall(from: item), tools: request.tools)
        if let existing = completedToolCalls[call.id] {
          guard phase == .terminal, existing == call else {
            throw ChatGPTWireError.duplicateResponse
          }
          return ([], false)
        }
        guard completedToolCalls.values.contains(where: { $0.name == call.name && $0.id == call.id }) == false else {
          throw ChatGPTWireError.duplicateResponse
        }
        completedToolCalls[call.id] = call
        toolCallOrder.append(call.id)
        return ([], false)
      }
      guard itemType == "message" else { throw ChatGPTWireError.policyViolation }
      if let role = chatGPTString(item, "role"), role != "assistant" {
        throw ChatGPTWireError.policyViolation
      }
      guard let itemID = chatGPTString(item, "id"), !itemID.isEmpty else {
        throw ChatGPTWireError.malformedSSE
      }
      if phase == .added {
        guard activeMessageID == nil, completedMessages[itemID] == nil,
          addedMessageIDs.insert(itemID).inserted
        else { throw ChatGPTWireError.duplicateResponse }
      }
      guard let rawContent = item["content"], let content = rawContent as? [Any] else {
        throw ChatGPTWireError.malformedSSE
      }
      var refusal = false
      var finalText = Data()
      for rawPart in content {
        guard let part = rawPart as? [String: Any], let partType = chatGPTString(part, "type")
        else {
          throw ChatGPTWireError.malformedSSE
        }
        switch partType {
        case "output_text":
          guard let text = part["text"] as? String else { throw ChatGPTWireError.malformedSSE }
          finalText.append(contentsOf: text.utf8)
        case "refusal":
          guard part["refusal"] is String else { throw ChatGPTWireError.malformedSSE }
          refusal = true
        default:
          throw ChatGPTWireError.policyViolation
        }
      }
      if let completed = completedMessages[itemID] {
        guard phase == .terminal, completed == finalText else {
          throw ChatGPTWireError.duplicateResponse
        }
        return ([], refusal)
      }
      if activeMessageID == nil {
        activeMessageID = itemID
        activeMessageStart = emittedBytes.count
      }
      guard activeMessageID == itemID else { throw ChatGPTWireError.invalidResponse }
      let current = Data(emittedBytes.dropFirst(activeMessageStart))
      let authoritative = phase != .added
      let compatible =
        finalText.starts(with: current)
        || (!authoritative && current.starts(with: finalText))
      guard compatible else {
        throw ChatGPTWireError.malformedSSE
      }
      var events: [ModelEvent] = []
      if finalText.count > current.count {
        let suffix = String(decoding: finalText.dropFirst(current.count), as: UTF8.self)
        events = try textDelta(suffix)
      }
      if authoritative {
        completedMessages[itemID] = finalText
        activeMessageID = nil
        activeMessageStart = emittedBytes.count
      }
      return (events, refusal)
    }

    private mutating func beginImplicitMessageIfNeeded(itemID: String?) throws {
      let identifier = itemID ?? activeMessageID ?? "__implicit_message__"
      if activeMessageID == nil {
        guard completedMessages[identifier] == nil else {
          throw ChatGPTWireError.duplicateResponse
        }
        activeMessageID = identifier
        activeMessageStart = emittedBytes.count
      }
      guard activeMessageID == identifier else { throw ChatGPTWireError.invalidResponse }
    }

    private mutating func textDelta(_ text: String) throws -> [ModelEvent] {
      let bytes = text.utf8.count
      let (next, overflow) = outputBytes.addingReportingOverflow(bytes)
      guard !overflow, next <= request.maxOutputBytes else {
        throw ModelGenerationFailure(.limitExceeded, "Provider text output exceeds the byte limit.")
      }
      outputBytes = next
      emittedBytes.append(contentsOf: text.utf8)
      var result: [ModelEvent] = []
      for delta in try request.limits.boundedDeltas(for: text) {
        result.append(.textDelta(delta))
      }
      return result
    }

    private func parseUsage(_ object: [String: Any]?) throws -> ModelUsage? {
      guard let object else { return nil }
      guard let input = chatGPTInteger(object, "input_tokens"),
        let output = chatGPTInteger(object, "output_tokens")
      else { throw ChatGPTWireError.malformedSSE }
      if let total = chatGPTInteger(object, "total_tokens") {
        let (sum, overflow) = input.addingReportingOverflow(output)
        guard !overflow, total == sum else { throw ChatGPTWireError.malformedSSE }
      }
      let (total, overflow) = input.addingReportingOverflow(output)
      guard !overflow else { throw ChatGPTWireError.malformedSSE }
      return ModelUsage(
        inputTokens: Int(input), outputTokens: Int(output), totalTokens: Int(total))
    }

    private func completionEvents(reason: ModelStopReason, usage: ModelUsage?) -> [ModelEvent] {
      var events: [ModelEvent] = []
      if let usage { events.append(.usage(usage)) }
      let toolCalls = toolCallOrder.compactMap { completedToolCalls[$0] }
      events.append(.completed(ModelTurn(
        content: String(decoding: emittedBytes, as: UTF8.self),
        toolCalls: toolCalls,
        usage: usage,
        stopReason: reason)))
      return events
    }
  }
  private static func validate(_ request: ModelRequest) throws {
    try request.validateGenerationContract()
    guard request.effectiveRequiredCapabilities.isSubset(
      of: [.textInput, .textOutput, .streaming, .structuredOutput, .toolCalls]
    ) else {
      throw ModelGenerationFailure(.invalidRequest, "ChatGPT subscription request uses unsupported capabilities.")
    }
    for message in request.messages {
      switch message.role {
      case .system, .user, .assistant: break
      case .tool:
        guard let callID = message.toolCallID, !callID.isEmpty else {
          throw ModelGenerationFailure(
            .invalidRequest, "ChatGPT subscription tool messages require a tool call identifier.")
        }
      }
      guard message.contentParts.allSatisfy({ if case .text = $0 { true } else { false } }) else {
        throw ModelGenerationFailure(.invalidRequest, "ChatGPT subscription text does not support media.")
      }
    }
  }
}
