import LanguageModelCore
import LanguageModelRuntime
import NativeLanguageModels
import Testing

@Suite("NativeLanguageModels projection")
struct LanguageModelSessionTests {
  @Test func optionsAndToolCallsUseTheCanonicalRequestAndReturnWithoutExecution() async throws {
    let probe = FacadeProbe()
    let runtime = try ModelRuntime(
      id: .init(rawValue: "facade"),
      model: ClientLanguageModel(client: FacadeClient(probe: probe)))
    let session = LanguageModelSession(
      id: "session", runtime: .borrowed(runtime), instructions: "rules")
    let tool = ModelTool(
      name: "lookup", description: "Read knowledge",
      inputSchema: .object(["type": .string("object")]))
    let turn = try await session.respond(
      to: "question", options: .init(tools: [tool], maxOutputBytes: 100, deadline: .seconds(3)))
    #expect(turn.toolCalls.map(\.name) == ["lookup"])
    let request = try #require(await probe.last)
    #expect(request.tools == [tool])
    #expect(request.maxOutputBytes == 100)
    #expect(request.deadline == .seconds(3))
    #expect(request.messages.map(\.content) == ["rules", "question"])
    #expect(await session.transcript.count == 3)
    try await session.close()
    #expect(await runtime.status().phase == .idle)
    try await runtime.shutdown()
  }

  @Test func streamAndRespondCommitTheSameKindOfTranscript() async throws {
    let probe = FacadeProbe()
    let model = try ClientLanguageModel(client: FacadeClient(probe: probe))
    let store = ModelExecutorStore()
    let session = try await LanguageModelSession(id: "stream", model: model, executorStore: store)
    var completions = 0
    for try await event in try await session.streamResponse(to: "question") {
      if case .completed(let turn) = event {
        completions += 1
        #expect(turn.content == "ok")
      }
    }
    #expect(completions == 1)
    #expect(await session.transcript.count == 2)
    try await session.close()
    try await store.shutdown()
  }

  @Test func unsupportedGuidedOutputDoesNotDispatch() async throws {
    let probe = FacadeProbe()
    let runtime = try ModelRuntime(
      id: .init(rawValue: "facade"),
      model: ClientLanguageModel(client: FacadeClient(probe: probe)))
    let session = LanguageModelSession(id: "session", runtime: .owned(runtime))
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await session.respond(
        to: "json",
        options: .init(outputFormat: .jsonObject(schema: .object(["type": .string("object")]))))
    }
    #expect(await probe.last == nil)
    try await session.close()
  }
}
private actor FacadeProbe {
  private(set) var last: ModelRequest?
  func respond(_ request: ModelRequest) -> ModelTurn {
    last = request
    return ModelTurn(
      content: "ok",
      toolCalls: request.tools.isEmpty
        ? [] : [.init(id: "call", name: "lookup", arguments: .object([:]))])
  }
}
private struct FacadeClient: ModelClient {
  let probe: FacadeProbe
  let providerID = "fixture.facade"
  var modelDescriptor: ModelDescriptor? {
    .init(
      id: "model", providerID: providerID,
      capabilities: [.textInput, .textOutput, .toolCalls, .streaming])
  }
  func generate(request: ModelRequest) async throws -> ModelTurn { await probe.respond(request) }
}
