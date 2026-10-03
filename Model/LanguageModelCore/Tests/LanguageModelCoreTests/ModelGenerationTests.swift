import Foundation
import Testing

@testable import LanguageModelCore

@Suite("Model generation contract")
struct ModelGenerationTests {
  @Test func toolCallMetadataRoundTripsAndParticipatesInDurableIdentity() throws {
    let signature = ["provider.gemini.thought_signature": JSONValue.string("signed")]
    let call = ToolCall(
      id: "call-1",
      name: "lookup",
      arguments: ["query": "weather"],
      metadata: signature)

    let encoded = try JSONValue.encode(call)
    let decoded = try encoded.decode(ToolCall.self)

    #expect(decoded == call)
    #expect(decoded.metadata == signature)
    #expect(
      ToolCall(name: call.name, arguments: call.arguments, metadata: signature).id
        != ToolCall(name: call.name, arguments: call.arguments).id)
  }

  @Test func generationLimitsRejectUnsupportedContractVersion() {
    #expect(throws: ModelGenerationFailure.self) {
      _ = try ModelGenerationLimits(version: "v2")
    }
  }

  @Test func requestFootprintUsesTheCanonicalGenerationByteAccounting() throws {
    let request = ModelRequest(
      sessionID: "footprint",
      messages: [
        AgentMessage(
          role: .user,
          contentParts: [
            .text("hello"),
            .image(.init(mimeType: "image/png", data: Data([1, 2, 3, 4])))
          ]
        )
      ],
      tools: []
    )

    let footprint = try request.inputFootprint()
    #expect(footprint.messageCount == 1)
    #expect(footprint.binaryPartCount == 1)
    #expect(footprint.binaryInputBytes == 4)
    #expect(footprint.inlineInputBytes > 0)
    #expect(footprint.aggregateInputBytes == footprint.inlineInputBytes + 4)
    try request.validateGenerationContract()
  }

  @Test func requestRoundTripsThroughJSONValueWithoutChangingDurableIdentity() throws {
    let request = textRequest()

    let persisted = try JSONValue.encode(request)
    let decoded = try persisted.decode(ModelRequest.self)

    #expect(decoded.deadline == request.deadline)
    #expect(decoded.limits == request.limits)
    #expect(decoded.messages == request.messages)
    #expect(decoded == request)
    #expect(try JSONValue.encode(decoded).canonicalString() == persisted.canonicalString())
  }

  @Test(arguments: ["outputFormat", "limits", "maxOutputBytes", "deadline"])
  func requestDecodeRequiresExplicitGenerationContract(field: String) throws {
    var object = try #require(JSONValue.encode(textRequest()).objectValue)
    object.removeValue(forKey: field)
    #expect(throws: DecodingError.self) {
      try JSONValue.object(object).decode(ModelRequest.self)
    }
    object[field] = .null
    #expect(throws: DecodingError.self) {
      try JSONValue.object(object).decode(ModelRequest.self)
    }
  }

  @Test func unicodeDeltasRespectByteBoundsAndRoundTrip() throws {
    let limits = try ModelGenerationLimits(maxDeltaBytes: 4)
    let source = "A한🙂B"
    let deltas = try limits.boundedDeltas(for: source)
    #expect(deltas.joined() == source)
    #expect(deltas.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4 })

    let oneByte = try ModelGenerationLimits(maxDeltaBytes: 1)
    #expect(throws: ModelGenerationFailure.self) {
      _ = try oneByte.boundedDeltas(for: "한")
    }
  }

  @Test func requestValidationRejectsInvalidIdentityInputAndOutputBounds() throws {
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "bad id", messages: [.init(role: .user, content: "hi")], tools: []
      )
      .validateGenerationContract()
    }
    let limits = try ModelGenerationLimits(maxMessageBytes: 2, maxInputBytes: 2)
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "bounded",
        messages: [.init(role: .user, content: "three")],
        tools: [],
        limits: limits
      ).validateGenerationContract()
    }
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "message-id",
        messages: [
          .init(id: "bad id", role: .user, content: "hello")
        ],
        tools: []
      ).validateGenerationContract()
    }
    let oversizedMessageValue = String(repeating: "x", count: 17 * 1_024)
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "message-metadata",
        messages: [
          .init(role: .user, content: "hello", metadata: ["large": .string(oversizedMessageValue)])
        ],
        tools: []
      ).validateGenerationContract()
    }
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "message-tool-call",
        messages: [
          .init(
            role: .assistant,
            content: "calling",
            toolCalls: [
              .init(
                id: "call-1",
                name: "lookup",
                arguments: .object(["large": .string(oversizedMessageValue)]))
            ])
        ],
        tools: []
      ).validateGenerationContract()
    }
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "tools",
        messages: [.init(role: .user, content: "tool")],
        tools: [
          .init(name: "duplicate", description: "a", inputSchema: .object([:])),
          .init(name: "duplicate", description: "b", inputSchema: .object([:])),
        ]
      ).validateGenerationContract()
    }
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "tool-schema",
        messages: [.init(role: .user, content: "tool")],
        tools: [.init(name: "lookup", description: "lookup", inputSchema: .array([]))]
      ).validateGenerationContract()
    }
    let mediaLimits = try ModelGenerationLimits(
      maxBinaryParts: 1,
      maxBinaryInputBytes: 2)
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "media",
        messages: [
          .init(
            role: .user,
            contentParts: [.image(.init(mimeType: "image/png", data: Data([1, 2, 3])))])
        ],
        tools: [],
        limits: mediaLimits
      ).validateGenerationContract()
    }
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "mime",
        messages: [
          .init(
            role: .user,
            contentParts: [.audio(.init(mimeType: "invalid type", data: Data([1])))])
        ],
        tools: []
      ).validateGenerationContract()
    }
    #expect(throws: ModelGenerationFailure.self) {
      try ModelRequest(
        sessionID: "schema",
        messages: [.init(role: .user, content: "json")],
        tools: [],
        outputFormat: .jsonObject(schema: .array([]))
      ).validateGenerationContract()
    }
  }

  @Test func collectorRequiresOneTerminalAndMatchingAuthoritativeText() throws {
    let request = textRequest()
    var valid = try ModelStreamCollector(request: request)
    try valid.receive(.started(descriptor: nil))
    try valid.receive(.textDelta("same"))
    try valid.receive(.completed(ModelTurn(content: "same", stopReason: .stop)))
    #expect(try valid.finish().content == "same")

    var mismatch = try ModelStreamCollector(request: request)
    try mismatch.receive(.started(descriptor: nil))
    try mismatch.receive(.textDelta("first"))
    #expect(throws: ModelGenerationFailure.self) {
      try mismatch.receive(.completed(ModelTurn(content: "second", stopReason: .stop)))
    }

    var missing = try ModelStreamCollector(request: request)
    try missing.receive(.started(descriptor: nil))
    #expect(throws: ModelStreamContractError.self) { _ = try missing.finish() }
  }

  @Test func collectorValidatesUsageOutputLimitAndJSONObjectShape() throws {
    let limits = try ModelGenerationLimits(maxOutputBytes: 8, maxDeltaBytes: 4)
    let request = ModelRequest(
      sessionID: "json",
      messages: [.init(role: .user, content: "json")],
      tools: [],
      outputFormat: .jsonObject(schema: .object(["type": .string("object")])),
      limits: limits)

    var valid = try ModelStreamCollector(request: request)
    try valid.receive(.started(descriptor: nil))
    try valid.receive(.textDelta("{\"a\""))
    try valid.receive(.textDelta(":1}"))
    let usage = ModelUsage(inputTokens: 1, outputTokens: 2, totalTokens: 3)
    try valid.receive(.usage(usage))
    try valid.receive(
      .completed(
        ModelTurn(
          content: "{\"a\":1}", usage: usage, stopReason: .stop)))
    #expect(try valid.finish().content == "{\"a\":1}")

    var malformed = try ModelStreamCollector(request: request)
    try malformed.receive(.started(descriptor: nil))
    try malformed.receive(.completed(ModelTurn(content: "not-json", stopReason: .stop)))
    #expect(throws: ModelGenerationFailure.self) { _ = try malformed.finish() }

    var invalidUsage = try ModelStreamCollector(request: textRequest())
    try invalidUsage.receive(.started(descriptor: nil))
    #expect(throws: ModelGenerationFailure.self) {
      try invalidUsage.receive(.usage(.init(inputTokens: 1, outputTokens: 1, totalTokens: 3)))
    }
  }

  @Test func collectorBoundsAuxiliaryAndDeclaredBinaryOutput() throws {
    let limits = try ModelGenerationLimits(
      maxBinaryOutputParts: 1,
      maxBinaryOutputBytes: 3,
      maxOutputBytes: 8,
      maxDeltaBytes: 4,
      maxFrameBytes: 8)
    let request = ModelRequest(
      sessionID: "binary-output",
      messages: [.init(role: .user, content: "speak")],
      tools: [],
      requiredCapabilities: [.textInput, .audioOutput, .streaming],
      limits: limits)

    var declared = try ModelStreamCollector(request: request)
    try declared.receive(.started(descriptor: nil))
    try declared.receive(
      .completed(
        ModelTurn(contentParts: [.audio(.init(mimeType: "audio/wav", data: Data([1, 2, 3])))])))
    #expect(try declared.finish().contentParts.count == 1)

    var oversized = try ModelStreamCollector(request: request)
    try oversized.receive(.started(descriptor: nil))
    #expect(throws: ModelGenerationFailure.self) {
      try oversized.receive(
        .completed(
          ModelTurn(contentParts: [.audio(.init(mimeType: "audio/wav", data: Data([1, 2, 3, 4])))]))
      )
    }

    var auxiliary = try ModelStreamCollector(request: request)
    try auxiliary.receive(.started(descriptor: nil))
    try auxiliary.receive(.reasoningDelta("1234"))
    #expect(throws: ModelGenerationFailure.self) {
      try auxiliary.receive(.reasoningDelta("56789"))
    }
  }

  @Test func runtimeNormalizesDeadlineCancellationAndProviderCancellation() async throws {
    let limits = try ModelGenerationLimits(maxDeadline: .milliseconds(20))
    let request = ModelRequest(
      sessionID: "deadline",
      messages: [.init(role: .user, content: "hello")],
      tools: [],
      limits: limits)
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await ModelStreamContract.completedTurn(from: stalledStream(), request: request)
    }

    let cancellable = Task {
      try await ModelStreamContract.completedTurn(from: stalledStream(), request: textRequest())
    }
    await Task.yield()
    cancellable.cancel()
    do {
      _ = try await cancellable.value
      Issue.record("Cancellation must fail.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .cancelled)
    }

    let providerCancelled = AsyncThrowingStream<ModelEvent, any Error> { continuation in
      continuation.yield(.started(descriptor: nil))
      continuation.finish(throwing: CancellationError())
    }
    do {
      _ = try await ModelStreamContract.completedTurn(
        from: providerCancelled,
        request: textRequest())
      Issue.record("Provider cancellation must fail.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .transportFailure)
    }
  }

  @Test func commonCapabilityValidationRejectsUnsupportedRequests() throws {
    let request = ModelRequest(
      sessionID: "capability",
      messages: [
        .init(
          role: .user,
          contentParts: [
            .text("describe"),
            .image(.init(mimeType: "image/png", data: Data([1])))
          ])
      ],
      tools: [])
    do {
      try request.validateSupportedCapabilities([.textInput, .textOutput])
      Issue.record("Unsupported image input must fail.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .policyViolation)
    }
  }

  @Test func usageEventsMergeIntoTerminalAndConflictsFail() throws {
    let request = textRequest()
    let usage = ModelUsage(inputTokens: 2, outputTokens: 3, totalTokens: 5)
    var collector = try ModelStreamCollector(request: request)
    _ = try collector.receive(.started(descriptor: nil))
    _ = try collector.receive(.usage(usage))
    _ = try collector.receive(.completed(ModelTurn(content: "done")))
    #expect(try collector.finish().usage == usage)

    var conflicting = try ModelStreamCollector(request: request)
    _ = try conflicting.receive(.started(descriptor: nil))
    _ = try conflicting.receive(.usage(usage))
    #expect(throws: ModelGenerationFailure.self) {
      _ = try conflicting.receive(
        .completed(
          ModelTurn(
            content: "done",
            usage: ModelUsage(inputTokens: 1, outputTokens: 1, totalTokens: 2)
          )
        )
      )
    }
  }

  @Test func textDeltaHonorsTheNarrowerFrameLimit() throws {
    let limits = try ModelGenerationLimits(
      maxDeltaBytes: 16,
      maxFrameBytes: 4
    )
    let request = ModelRequest(
      sessionID: "frame",
      messages: [.init(role: .user, content: "hello")],
      tools: [],
      limits: limits
    )
    var collector = try ModelStreamCollector(request: request)
    _ = try collector.receive(.started(descriptor: nil))
    do {
      _ = try collector.receive(.textDelta("12345"))
      Issue.record("A text frame above maxFrameBytes must fail.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .limitExceeded)
    }
  }

  @Test func modelToolContractIsTheSingleRequestAndTurnBound() throws {
    #expect(ModelToolContract.maximumDefinitionCount == 32)
    #expect(ModelToolContract.maximumCallsPerMessage == 32)
    #expect(ModelToolContract.maximumHistoricalCallsPerRequest == 32)
    #expect(ModelToolContract.maximumCallsPerTurn == 32)

    let schema: JSONValue = .object(["type": .string("object")])
    let tools = (0..<ModelToolContract.maximumDefinitionCount).map { index in
      ModelTool(name: "tool_\(index)", description: "tool", inputSchema: schema)
    }
    let accepted = ModelRequest(
      sessionID: "tool.contract.accepted",
      messages: [.init(role: .user, content: "hello")],
      tools: tools
    )
    try accepted.validateGenerationContract()

    let rejected = ModelRequest(
      sessionID: "tool.contract.rejected",
      messages: [.init(role: .user, content: "hello")],
      tools: tools + [ModelTool(name: "tool_overflow", description: "tool", inputSchema: schema)]
    )
    #expect(throws: ModelGenerationFailure.self) {
      try rejected.validateGenerationContract()
    }

    let calls = (0...ModelToolContract.maximumCallsPerTurn).map { index in
      ToolCall(id: "call_\(index)", name: "tool_0", arguments: .object([:]))
    }
    #expect(throws: ModelGenerationFailure.self) {
      try ModelTurn(content: "done", toolCalls: calls).validateGenerationContract(for: accepted)
    }
  }

  private func textRequest() -> ModelRequest {
    ModelRequest(
      sessionID: "request.v1",
      messages: [.init(role: .user, content: "hello")],
      tools: [])
  }

  private func stalledStream() -> AsyncThrowingStream<ModelEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.started(descriptor: nil))
      let task = Task {
        do {
          try await Task.sleep(for: .seconds(30))
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
