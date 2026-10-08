import Foundation
import Testing

@testable import LanguageModelCore

@Test
func typedContentRoundTripsAndProducesTextProjection() throws {
    let image = ModelBinaryContent(mimeType: "image/png", data: Data([1, 2, 3]), filename: "image.png")
    let message = AgentMessage(role: .user, contentParts: [.text("describe"), .image(image)])

    #expect(message.content == "describe")
    #expect(message.contentParts == [.text("describe"), .image(image)])
    #expect(try JSONDecoder.nativeAgent().decode(AgentMessage.self, from: JSONEncoder.nativeAgent().encode(message)) == message)
}

@Test
func assistantTerminalFactsSurviveEventsAndCodableRoundTrip() throws {
    let image = ModelBinaryContent(mimeType: "image/png", data: Data([4, 5, 6]), filename: "result.png")
    let usage = ModelUsage(inputTokens: 12, outputTokens: 8, totalTokens: 20)
    let message = AgentMessage(
        role: .assistant,
        contentParts: [.text("answer"), .image(image)],
        createdAt: Date(timeIntervalSince1970: 123),
        toolCalls: [
            ToolCall(name: "lookup", arguments: .object(["query": .string("value")]))
        ],
        metadata: ["phase": .string("complete")],
        usage: usage,
        responseID: "response-123",
        reasoningSummary: "A concise answer was produced.",
        stopReason: .maxTokens
    )

    #expect(message.contentParts == [.text("answer"), .image(image)])
    #expect(message.usage == usage)
    #expect(message.responseID == "response-123")
    #expect(message.reasoningSummary == "A concise answer was produced.")
    #expect(message.stopReason == .maxTokens)

    let sameTextDifferentStopReason = AgentMessage(
        role: .assistant,
        content: "answer",
        stopReason: .stop
    )
    let sameTextMaxTokens = AgentMessage(
        role: .assistant,
        content: "answer",
        stopReason: .maxTokens
    )
    #expect(sameTextDifferentStopReason.id != sameTextMaxTokens.id)

    let contentChanged = message.applying(.contentChanged("revised"))
    let metadataChanged = contentChanged.applying(
        .metadataChanged(["phase": .string("revised")])
    )

    for updated in [contentChanged, metadataChanged] {
        #expect(updated.usage == usage)
        #expect(updated.responseID == "response-123")
        #expect(updated.reasoningSummary == "A concise answer was produced.")
        #expect(updated.stopReason == .maxTokens)
    }
    #expect(metadataChanged.content == "revised")
    #expect(metadataChanged.metadata == ["phase": .string("revised")])

    let roundTripped = try JSONDecoder.nativeAgent().decode(
        AgentMessage.self,
        from: JSONEncoder.nativeAgent().encode(metadataChanged)
    )
    #expect(roundTripped == metadataChanged)
}

@Test
func currentMessageAndTurnPayloadsRejectMissingOrContradictoryContentParts() throws {
    let encoder = JSONEncoder.nativeAgent()
    let decoder = JSONDecoder.nativeAgent()
    let message = AgentMessage(role: .user, contentParts: [.text("canonical")])
    let turn = ModelTurn(contentParts: [.text("canonical")])

    var messageObject = try #require(
        decoder.decode(JSONValue.self, from: encoder.encode(message)).objectValue
    )
    messageObject["content"] = .string("contradiction")
    #expect(throws: DecodingError.self) {
        try decoder.decode(
            AgentMessage.self,
            from: encoder.encode(JSONValue.object(messageObject))
        )
    }

    messageObject["content"] = .string("canonical")
    messageObject["contentParts"] = nil
    #expect(throws: DecodingError.self) {
        try decoder.decode(
            AgentMessage.self,
            from: encoder.encode(JSONValue.object(messageObject))
        )
    }

    var turnObject = try #require(
        decoder.decode(JSONValue.self, from: encoder.encode(turn)).objectValue
    )
    turnObject["content"] = .string("contradiction")
    #expect(throws: DecodingError.self) {
        try decoder.decode(
            ModelTurn.self,
            from: encoder.encode(JSONValue.object(turnObject))
        )
    }

    turnObject["content"] = .string("canonical")
    turnObject["contentParts"] = nil
    #expect(throws: DecodingError.self) {
        try decoder.decode(
            ModelTurn.self,
            from: encoder.encode(JSONValue.object(turnObject))
        )
    }
}

@Test
func modelRequestDerivesMediaAndToolRequirements() {
    let request = ModelRequest(
        sessionID: "session",
        messages: [
            AgentMessage(role: .user, contentParts: [
                .image(.init(mimeType: "image/png", data: Data([1])))
            ])
        ],
        tools: [ModelTool(name: "lookup", description: "Lookup", inputSchema: .object([:]))]
    )

    #expect(request.effectiveRequiredCapabilities.contains(.textInput))
    #expect(request.effectiveRequiredCapabilities.contains(.imageInput))
    #expect(request.effectiveRequiredCapabilities.contains(.toolCalls))
    #expect(!request.effectiveRequiredCapabilities.contains(.structuredOutput))
}

@Test
func structuredOutputIsAnEffectiveCapability() throws {
    let request = ModelRequest(
        sessionID: "session-structured",
        messages: [.init(role: .user, content: "return json")],
        tools: [],
        outputFormat: .jsonObject(schema: .object(["type": .string("object")]))
    )

    #expect(request.effectiveRequiredCapabilities.contains(.structuredOutput))
    #expect(throws: ModelGenerationFailure.self) {
        try request.validateSupportedCapabilities([.textInput, .textOutput])
    }
    try request.validateSupportedCapabilities([.textInput, .textOutput, .structuredOutput])
}

@Test
func modelStreamContractRequiresOneStartedAndOneTerminalCompletedEvent() async throws {
    let empty = ModelStreamContractState()
    #expect(throws: ModelStreamContractError.missingStartedEvent) {
        _ = try empty.finish()
    }

    var valid = ModelStreamContractState()
    try valid.consume(.started(descriptor: nil))
    try valid.consume(.textDelta("hel"))
    try valid.consume(.textDelta("lo"))
    let turn = ModelTurn(content: "hello")
    try valid.consume(.completed(turn))
    #expect(try valid.finish() == turn)

    var missingStart = ModelStreamContractState()
    #expect(throws: ModelStreamContractError.self) {
        try missingStart.consume(.textDelta("invalid"))
    }

    var duplicateStart = ModelStreamContractState()
    try duplicateStart.consume(.started(descriptor: nil))
    #expect(throws: ModelStreamContractError.self) {
        try duplicateStart.consume(.started(descriptor: nil))
    }

    var afterCompletion = ModelStreamContractState()
    try afterCompletion.consume(.started(descriptor: nil))
    try afterCompletion.consume(.completed(turn))
    #expect(throws: ModelStreamContractError.self) {
        try afterCompletion.consume(.usage(.init(inputTokens: 1)))
    }

    var duplicateCompletion = ModelStreamContractState()
    try duplicateCompletion.consume(.started(descriptor: nil))
    try duplicateCompletion.consume(.completed(turn))
    #expect(throws: ModelStreamContractError.duplicateCompletedEvent) {
        try duplicateCompletion.consume(.completed(turn))
    }
}

@Test
func descriptorValidationAllowsRepositoryPathsButRejectsWhitespaceAndUnknownCapabilities() throws {
  try ModelDescriptor(
    id: "mlx-community/Llama-3.2",
    providerID: "mlx.text",
    displayName: "Llama 3.2",
    capabilities: [.textInput, .textOutput, .streaming],
    contextWindowTokens: 131_072
  ).validateGenerationContract()

  #expect(throws: ModelGenerationFailure.self) {
    try ModelDescriptor(
      id: "invalid model",
      providerID: "mlx.text"
    ).validateGenerationContract()
  }

  #expect(throws: ModelGenerationFailure.self) {
    try ModelDescriptor(
      id: "model",
      providerID: "provider",
      capabilities: ModelCapabilities(rawValue: 1 << 63)
    ).validateGenerationContract()
  }
}

@Test
func providerCancellationCodeWithoutCallerCancellationIsTransportFailure() async throws {
    let request = ModelRequest(sessionID: "provider-cancel", messages: [.init(role: .user, content: "hello")], tools: [])
    let stream = AsyncThrowingStream<ModelEvent, any Error> { continuation in
        continuation.yield(.started(descriptor: nil))
        continuation.finish(throwing: ModelGenerationFailure(.cancelled, "Provider cancelled itself."))
    }
    do {
        _ = try await ModelStreamContract.completedTurn(from: stream, request: request)
        Issue.record("An unsolicited provider cancellation returned success.")
    } catch let failure as ModelGenerationFailure {
        #expect(failure.code == .transportFailure)
    }
}

private actor CancellationAtEOFSource {
    private var index = 0
    func next() -> ModelEvent? {
        defer { index += 1 }
        switch index {
        case 0: return .started(descriptor: nil)
        case 1: return .completed(ModelTurn(content: "done"))
        default:
            withUnsafeCurrentTask { $0?.cancel() }
            return nil
        }
    }
}

@Test
func cancellationAtEOFDoesNotReturnSuccessfulCompletedTurn() async throws {
    let operation = Task {
        let source = CancellationAtEOFSource()
        let stream = AsyncThrowingStream<ModelEvent, any Error>(unfolding: { await source.next() })
        do {
            _ = try await ModelStreamContract.completedTurn(from: stream)
            Issue.record("Cancellation at EOF was flattened into success.")
        } catch is CancellationError {}
    }
    try await operation.value
}
