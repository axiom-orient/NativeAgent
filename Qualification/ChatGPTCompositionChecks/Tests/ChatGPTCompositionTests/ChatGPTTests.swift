@_spi(Service) @testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import LanguageModelCore
import CryptoKit
import Foundation
import os
import Testing


#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("ChatGPT ChatGPT subscription", .serialized)
struct ChatGPTTests {
  // Requires the real Account/Text modules on a supported Apple SDK. Not part of
  // the portable wire slice; controlled transport proves ordering, not live auth.
  @Test func modelInvocationOwnsTextSSEAndTransportUntilCompletion() async throws {
    let gate = TransportSettlementGate()
    let client = try ownedClient(gate: gate)
    let starts = OSAllocatedUnfairLock(initialState: 0)
    let operation = client.invocation(request: ownedRequest(), onStarted: {
      starts.withLock { $0 += 1 }
    })
    let reader = Task {
      let result = try await ModelStreamContract.completedTurn(from: operation.events, request: ownedRequest())
      #expect(await gate.isReleased)
      return result
    }
    await gate.waitUntilJoined()
    #expect(starts.withLock { $0 } == 1)
    await gate.release()
    #expect(try await reader.value.content == "hello")
    try await operation.waitForCompletion()
    try await operation.waitForCompletion()
  }

  @Test func cancelledModelInvocationStillJoinsTheTransport() async throws {
    let gate = TransportSettlementGate()
    let operation = try ownedClient(gate: gate).invocation(request: ownedRequest(), onStarted: {})
    await gate.waitUntilJoined()
    operation.cancel()
    operation.cancel()
    let waiter = Task { try await operation.waitForCompletion() }
    waiter.cancel()
    await gate.release()
    try await waiter.value
    do {
      for try await _ in operation.events {}
      Issue.record("Cancelled model operation reported success.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .cancelled)
    }
    #expect(gate.cancelCount > 0)
  }

  @Test func modelInvocationPreservesUnprovedDrainInsteadOfSuccessfulCompletion() async throws {
    let gate = TransportSettlementGate(fails: true)
    let operation = try ownedClient(gate: gate).invocation(request: ownedRequest(), onStarted: {})
    await gate.waitUntilJoined()
    await gate.release()
    await #expect(throws: ModelExecutorDrainFailure.self) {
      for try await _ in operation.events {}
    }
    await #expect(throws: ModelExecutorDrainFailure.self) {
      try await operation.waitForCompletion()
    }
  }

  private func ownedRequest() -> ModelRequest {
    ModelRequest(sessionID: "owned-completion", messages: [.init(role: .user, content: "Hello")], tools: [])
  }

  private func ownedClient(gate: TransportSettlementGate) throws -> ChatGPTModelClient {
    let account = ChatGPTAccountSession(profile: .codexSubscription,
      store: MemoryCredentialStore(tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600))),
      transport: generationCatalogTransport())
    let body = """
      data: {"type":"response.output_text.delta","delta":"hello"}

      data: {"type":"response.completed","response":{"id":"owned-response","output":[]}}


      """
    return try ChatGPTModelClient(account: account,
      transport: GatedTransport(gate: gate, body: Data(body.utf8)))
  }

  @Test func authorizationLeaseCannotEscapePinnedServiceOrigin() async throws {
    let session = ChatGPTAccountSession(
      profile: .codexSubscription,
      store: MemoryCredentialStore(tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600))),
      transport: FixtureTransport([]))
    let lease = try await session.requestAuthorization()
    var unsafe = URLRequest(url: URL(string: "https://example.invalid/collect")!)
    #expect(throws: ChatGPTFailure.self) { try lease.apply(to: &unsafe) }
    #expect(unsafe.value(forHTTPHeaderField: "Authorization") == nil)
    try await session.signOut()
    await #expect(throws: ChatGPTFailure.self) { try await session.validateAuthorization(lease) }
  }

  @Test func cachedCatalogCannotSurviveSignOut() async throws {
    let transport = FixtureTransport([
      .json(200, ["models": [["slug": "first", "visibility": "list", "priority": 1]]])
    ])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription,
      store: MemoryCredentialStore(tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600))),
      transport: transport)
    let text = ChatGPTTextSession(account: session)
    #expect(try await text.models().first?.slug == "first")
    try await session.signOut()
    await #expect(throws: ChatGPTFailure.self) { _ = try await text.models() }
    #expect(await transport.requests.count == 1)
  }

  @Test func whitespaceImageIntentFailsBeforeAuthenticationOrDispatch() async throws {
    let transport = FixtureTransport([])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)
    do {
      _ = try await client.generate(.init(prompt: " \n ", background: .transparent))
      Issue.record("An empty user prompt must not become a background-only paid request")
    } catch let failure as ChatGPTImageFailure {
      #expect(failure.code == .invalidRequest)
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func webAuthorizationStoresAccountAndNeverUsesAnAPIKey() async throws {
    let tokens = tokenResponse(expiration: Date().addingTimeInterval(3_600))
    let transport = FixtureTransport([
      .data(200, tokens)
    ])
    let store = MemoryCredentialStore()
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)

    let authorization = try await session.beginSignIn()
    #expect(try await session.beginSignIn() == authorization)
    #expect(authorization.authorizationURL.host == "auth.openai.com")
    #expect(authorization.authorizationURL.path == "/oauth/authorize")
    let query = try #require(
      URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false))
    let state = try #require(query.queryItems?.first(where: { $0.name == "state" })?.value)
    #expect(query.queryItems?.first(where: { $0.name == "response_type" })?.value == "code")
    #expect(query.queryItems?.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
    #expect(
      query.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
        == authorization.redirectURI.absoluteString)
    let firstCompletion = Task { try await session.completeSignIn(authorization) }
    let secondCompletion = Task { try await session.completeSignIn(authorization) }
    let (_, response) = try await sendCallback(
      authorization, code: "authorization-1", state: state)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let account = try await firstCompletion.value
    #expect(try await secondCompletion.value == account)
    #expect(account.accountID == "account-1")
    let status = try await session.status()
    #expect(status == .ready(account))
    #expect(try store.load()?.refreshToken == "refresh-1")

    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].url?.path == "/oauth/token")
    let body = String(decoding: try #require(requests[0].httpBody), as: UTF8.self)
    #expect(body.contains("grant_type=authorization_code"))
    #expect(
      body.contains(
        "redirect_uri=http%3A%2F%2Flocalhost%3A\(authorization.redirectURI.port!)%2Fauth%2Fcallback"))
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "api-key") == nil })
    #expect(
      requests.allSatisfy { request in
        guard let authorization = request.value(forHTTPHeaderField: "Authorization") else {
          return true
        }
        return !authorization.contains("sk-")
      })
  }

  @Test func concurrentBeginSignInSharesOneStartingOperation() async throws {
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: FixtureTransport([]))
    let first = Task { try await session.beginSignIn() }
    let second = Task { try await session.beginSignIn() }
    let firstAuthorization = try await first.value
    let secondAuthorization = try await second.value

    #expect(firstAuthorization == secondAuthorization)
    try await session.cancelSignIn()
  }

  @Test func mismatchedWebCallbackStateFailsBeforeTokenExchange() async throws {
    let transport = FixtureTransport([])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)
    let authorization = try await session.beginSignIn()
    let completion = Task { try await session.completeSignIn(authorization) }
    let (_, response) = try await sendCallback(
      authorization, code: "authorization-1", state: "wrong")
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    await #expect(throws: ChatGPTFailure.self) { _ = try await completion.value }
    #expect(await transport.requests.isEmpty)
  }

  @Test @MainActor func boundFallbackRedirectFlowsThroughAuthorizationAndTokenExchange() async throws {
    var occupier: ChatGPTLocalhostCallbackServer?
    do {
      let candidate = try ChatGPTLocalhostCallbackServer(port: ChatGPTProtocolProfile.defaultCallbackPort)
      try await candidate.start()
      occupier = candidate
    } catch {
      guard ChatGPTLocalhostCallbackServer.isAddressInUse(error) else { throw error }
    }
    do {
      let transport = FixtureTransport([.data(200, tokenResponse(expiration: Date().addingTimeInterval(3_600)))])
      let session = ChatGPTAccountSession(
        profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)
      let authorization = try await session.beginSignIn()
      let query = try #require(
        URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false))
      #expect(
        query.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
          == "http://localhost:1457/auth/callback")
      let state = try #require(query.queryItems?.first(where: { $0.name == "state" })?.value)
      let completion = Task { try await session.completeSignIn(authorization) }
      let (_, response) = try await sendCallback(
        authorization, code: "authorization-1", state: state)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      _ = try await completion.value

      let requests = await transport.requests
      #expect(requests.count == 1)
      let body = String(decoding: try #require(requests[0].httpBody), as: UTF8.self)
      #expect(body.contains("redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback"))
      try await occupier?.cancel()
    } catch {
      try? await occupier?.cancel()
      throw error
    }
  }

  @Test func callbackRedirectPolicyRejectsAnUnregisteredPort() throws {
    #expect(throws: ChatGPTFailure.self) {
      try ChatGPTProtocolProfile.validateCallbackRedirectURI(
        URL(string: "http://localhost:1456/auth/callback")!)
    }
  }


  @Test func callbackRedirectPolicyRejectsOutOfRangeIntegerPortWithoutTrapping() throws {
    #expect(throws: ChatGPTFailure.self) {
      try ChatGPTProtocolProfile.validateCallbackRedirectURI(
        URL(string: "http://localhost:65536/auth/callback")!)
    }
  }

  @Test func exactModelSelectionMustExistInCurrentAccountCatalog() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let transport = FixtureTransport([
      .json(200, ["models": [["slug": "available", "visibility": "list", "priority": 1]]])
    ])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let text = ChatGPTTextSession(account: session)

    await #expect(throws: ChatGPTFailure.self) {
      _ = try await text.modelID(for: .exact("not-in-catalog"))
    }
  }

  @Test func lateModelCatalogCannotRepopulateStateAfterSignOut() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let transport = ControlledTransport()
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let text = ChatGPTTextSession(account: session)

    let request = Task { try await text.models(forceRefresh: true) }
    for _ in 0..<1_000 {
      if await transport.started { break }
      await Task.yield()
    }
    #expect(await transport.started)
    try await session.signOut()
    let body = try JSONSerialization.data(
      withJSONObject: ["models": [["slug": "stale", "visibility": "list", "priority": 1]]]
    )
    await transport.finish(status: 200, body: body)
    await #expect(throws: ChatGPTFailure.self) { _ = try await request.value }
    await #expect(throws: ChatGPTFailure.self) { _ = try await text.models() }
  }

  @Test func lateRateLimitsCannotReturnAfterSignOut() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let transport = ControlledTransport()
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let text = ChatGPTTextSession(account: session)

    let request = Task { try await text.rateLimits() }
    for _ in 0..<1_000 {
      if await transport.started { break }
      await Task.yield()
    }
    #expect(await transport.started)
    try await session.signOut()
    let body = try JSONSerialization.data(withJSONObject: [
      "rate_limit": [
        "allowed": true,
        "limit_reached": false,
        "primary_window": ["used_percent": 10],
      ]
    ])
    await transport.finish(status: 200, body: body)
    await #expect(throws: ChatGPTFailure.self) { _ = try await request.value }
  }

  @Test func repeatedCancelIsIdempotentAndAllowsImmediateRebind() async throws {
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: FixtureTransport([]))
    _ = try await session.beginSignIn()
    let first = Task { try await session.cancelSignIn() }
    let second = Task { try await session.cancelSignIn() }
    try await first.value
    try await second.value
    let rebound = try await session.beginSignIn()
    try await session.cancelSignIn()
    #expect(
      ChatGPTProtocolProfile.registeredCallbackPorts.contains(UInt16(rebound.redirectURI.port!)))
  }

  @Test func registeredCallbackPortsAreExplicitAndOrdered() throws {
    #expect(ChatGPTProtocolProfile.registeredCallbackPorts == [1_455, 1_457])
    #expect(
      try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_455)
        == URL(string: "http://localhost:1455/auth/callback"))
    #expect(
      try ChatGPTProtocolProfile.callbackRedirectURI(port: 1_457)
        == URL(string: "http://localhost:1457/auth/callback"))
  }

  @Test func recommendedModelAndSubscriptionStreamUseCodexAccountHeaders() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let sse = """
      data: {"type":"response.output_text.delta","delta":"{\\"actionID\\":\\"hydrate\\"}"}

      data: {"type":"response.completed","response":{"id":"response-1","output":[],"usage":{"input_tokens":12,"output_tokens":6,"total_tokens":18}}}

      """
    let transport = FixtureTransport([
      .json(
        200,
        [
          "models": [
            ["slug": "hidden", "visibility": "hide", "priority": 0, "supported_in_api": true],
            [
              "slug": "gpt-subscription", "visibility": "list", "priority": 1,
              "supported_in_api": true,
            ],
          ]
        ]),
      .sse(200, sse),
    ])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTModelClient(account: session, transport: transport)
    let request = ModelRequest(
      sessionID: "subscription-proof",
      messages: [.init(role: .user, content: "Choose one action")],
      tools: [],
      outputFormat: .jsonObject(schema: .object(["type": .string("object")])))

    let output = try await client.generate(request: request)
    #expect(output.content == #"{"actionID":"hydrate"}"#)
    #expect(output.usage?.totalTokens == 18)

    let requests = await transport.requests
    #expect(requests.count == 2)
    let generation = requests[1]
    #expect(generation.url == ChatGPTProtocolProfile.codexSubscription.responsesEndpoint)
    #expect(generation.value(forHTTPHeaderField: "Chatgpt-Account-Id") == "account-1")
    #expect(generation.value(forHTTPHeaderField: "Originator") == "codex_cli_rs")
    #expect(generation.value(forHTTPHeaderField: "api-key") == nil)
    let body = try #require(generation.httpBody)
    let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(root["model"] as? String == "gpt-subscription")
    #expect(root["tools"] == nil)
    #expect(root["parallel_tool_calls"] as? Bool == false)
    let text = try #require(root["text"] as? [String: Any])
    let format = try #require(text["format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    #expect(format["strict"] as? Bool == true)
    #expect(format["schema"] as? [String: String] == ["type": "object"])
  }

  @Test func dottedFunctionNamesRoundTripWithoutCanonicalRename() throws {
    let names = ["files.writeText", "files_writeText", "na_test", String(repeating: "x", count: 100), "도구"]
    let tools = names.map { ModelTool(name: $0, description: "test", inputSchema: .object(["type": "object"])) }
    let encoded = try ChatGPTToolWireCodec.tools(tools)
    #expect(Set(encoded.compactMap { $0["name"] as? String }).count == names.count)
    for (tool, wire) in zip(tools, encoded) {
      let name = try #require(wire["name"] as? String)
      #expect(name.utf8.count <= 64)
      #expect(name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil)
      let call = ToolCall(id: "call", name: tool.name, arguments: .object([:]))
      let history = try ChatGPTToolWireCodec.inputItems(for: [.init(role: .assistant, content: "", toolCalls: [call])])
      #expect(history[0]["name"] as? String == name)
      let decoded = try ChatGPTToolWireCodec.canonicalCall(ToolCall(id: "call", name: name, arguments: .object([:])), tools: tools)
      #expect(decoded == call)
    }
    #expect(throws: ModelGenerationFailure.self) {
      try ChatGPTToolWireCodec.canonicalCall(ToolCall(id: "bad", name: "unregistered", arguments: .object([:])), tools: tools)
    }
  }

  @Test func subscriptionToolCallsUseCanonicalResponsesFunctionWireContract() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let sse = """
      data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\\"query\\\":\\\"tea\\\"}"}

      data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call-1","name":"lookup","arguments":"{\\\"query\\\":\\\"tea\\\"}"}}

      data: {"type":"response.completed","response":{"id":"response-tool-1","output":[],"usage":{"input_tokens":10,"output_tokens":3,"total_tokens":13}}}

      """
    let transport = FixtureTransport([.sse(200, sse)])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: generationCatalogTransport())
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
    let tool = ModelTool(
      name: "lookup",
      description: "Look up one value.",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string")])]),
        "required": .array([.string("query")]),
        "additionalProperties": .bool(false),
      ])
    )
    let request = ModelRequest(
      sessionID: "tool-proof",
      messages: [.init(role: .user, content: "look up tea")],
      tools: [tool]
    )

    let turn = try await client.generate(request: request)
    #expect(turn.stopReason == .toolUse)
    #expect(turn.toolCalls == [ToolCall(id: "call-1", name: "lookup", arguments: ["query": "tea"])])

    let recordedRequests = await transport.requests
    let generation = try #require(recordedRequests.first)
    let body = try #require(generation.httpBody)
    let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(root["tool_choice"] as? String == "auto")
    #expect(root["parallel_tool_calls"] as? Bool == false)
    let tools = try #require(root["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["type"] as? String == "function")
    #expect(tools[0]["name"] as? String == "lookup")
    #expect(tools[0]["strict"] as? Bool == false)
  }

  @Test func subscriptionToolHistoryMapsFunctionCallAndFunctionCallOutput() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let sse = """
      data: {"type":"response.output_text.delta","delta":"done"}

      data: {"type":"response.completed","response":{"id":"response-tool-history","output":[],"usage":{"input_tokens":9,"output_tokens":1,"total_tokens":10}}}

      """
    let transport = FixtureTransport([.sse(200, sse)])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: generationCatalogTransport())
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
    let call = ToolCall(id: "call-history", name: "lookup", arguments: ["query": "tea"])
    let request = ModelRequest(
      sessionID: "tool-history",
      messages: [
        .init(role: .user, content: "look up tea"),
        .init(role: .assistant, content: "", toolCalls: [call]),
        .init(role: .tool, content: "green tea", toolCallID: call.id, toolName: call.name),
        .init(role: .user, content: "summarize"),
      ],
      tools: [ModelTool(name: "lookup", description: "Look up one value.", inputSchema: .object(["type": "object"]))]
    )

    _ = try await client.generate(request: request)
    let recordedRequests = await transport.requests
    let generation = try #require(recordedRequests.first)
    let body = try #require(generation.httpBody)
    let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let input = try #require(root["input"] as? [[String: Any]])
    #expect(input.contains { $0["type"] as? String == "function_call" && $0["call_id"] as? String == call.id })
    #expect(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == call.id && $0["output"] as? String == "green tea" })
  }

  @Test func subscriptionToolHistoryPreservesStructuredMachineObservation() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let sse = """
      data: {"type":"response.output_text.delta","delta":"done"}

      data: {"type":"response.completed","response":{"id":"response-structured-tool-history","output":[],"usage":{"input_tokens":9,"output_tokens":1,"total_tokens":10}}}

      """
    let transport = FixtureTransport([.sse(200, sse)])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: generationCatalogTransport())
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
    let call = ToolCall(id: "call-structured-history", name: "files.readText", arguments: ["path": "value.txt"])
    let toolMessage = AgentMessage(
      role: .tool,
      content: "hello",
      toolCallID: call.id,
      toolName: call.name,
      metadata: [
        "output": .object(["content": .string("hello"), "sha256": .string("sha-1")]),
        "isError": .bool(false),
        "artifacts": .array([]),
        "byteCount": .integer(5)
      ]
    )
    let request = ModelRequest(
      sessionID: "structured-tool-history",
      messages: [
        .init(role: .user, content: "read"),
        .init(role: .assistant, content: "", toolCalls: [call]),
        toolMessage,
        .init(role: .user, content: "continue"),
      ],
      tools: [ModelTool(name: call.name, description: "read", inputSchema: .object(["type": "object"]))]
    )

    _ = try await client.generate(request: request)
    let generation = try #require((await transport.requests).first)
    let body = try #require(generation.httpBody)
    let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let input = try #require(root["input"] as? [[String: Any]])
    let outputItem = try #require(input.first { $0["type"] as? String == "function_call_output" })
    let observationString = try #require(outputItem["output"] as? String)
    let observation = try #require(
      JSONSerialization.jsonObject(with: Data(observationString.utf8)) as? [String: Any]
    )
    let output = try #require(observation["output"] as? [String: Any])
    let metadata = try #require(observation["metadata"] as? [String: Any])
    #expect(toolMessage.content == "hello")
    #expect(output["sha256"] as? String == "sha-1")
    #expect(metadata["byteCount"] as? Int == 5)
    #expect(observation["isError"] as? Bool == false)
  }

  @Test func recommendedModelSelectionFailsClosedWhenNoVisibleModelExists() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let transport = FixtureTransport([
      .json(
        200,
        ["models": [["slug": "hidden", "visibility": "hide", "priority": 0]]])
    ])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let text = ChatGPTTextSession(account: session)

    await #expect(throws: ChatGPTFailure.self) {
      _ = try await text.modelID(for: .recommended)
    }
    #expect(await transport.requests.count == 1)
  }

  @Test func modelCatalogExposesAccountModelMetadata() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let transport = FixtureTransport([
      .json(
        200,
        [
          "models": [
            [
              "slug": "gpt-codex",
              "display_name": "GPT Codex",
              "description": "Codex model",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                ["effort": "low", "description": "Fast"],
                ["effort": "medium", "description": "Balanced"],
              ],
              "visibility": "list",
              "supported_in_api": true,
              "priority": 2,
              "context_window": 272_000,
            ]
          ]
        ])
    ])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let text = ChatGPTTextSession(account: session)

    let models = try await text.models()
    let model = try #require(models.first)
    #expect(model.slug == "gpt-codex")
    #expect(model.displayName == "GPT Codex")
    #expect(model.defaultReasoningLevel == "medium")
    #expect(model.supportedReasoningLevels.map(\.effort) == ["low", "medium"])
    #expect(model.contextWindow == 272_000)
    #expect(await transport.requests.first?.url?.path == "/backend-api/codex/models")
  }

  @Test func rateLimitsExposeRemainingQuotaWindows() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let transport = FixtureTransport([
      .json(
        200,
        [
          "plan_type": "plus",
          "rate_limit": [
            "allowed": true,
            "limit_reached": false,
            "primary_window": [
              "used_percent": 42,
              "limit_window_seconds": 18_000,
              "reset_after_seconds": 1_200,
              "reset_at": 1_735_693_320,
            ],
            "secondary_window": [
              "used_percent": 5,
              "limit_window_seconds": 604_800,
              "reset_at": 1_735_696_800,
            ],
          ],
          "rate_limit_reached_type": ["type": "none"],
          "spend_control": [
            "reached": false,
            "individual_limit": [
              "limit": "25000",
              "used": "8000",
              "remaining": "17000",
              "remaining_percent": 68,
              "reset_at": 1_735_696_800,
            ],
          ],
          "rate_limit_reset_credits": ["available_count": 3],
        ])
    ])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let text = ChatGPTTextSession(account: session)

    let limits = try await text.rateLimits()
    #expect(limits.planType == "plus")
    #expect(limits.allowed == true)
    #expect(limits.limitReached == false)
    #expect(limits.primaryWindow?.usedPercent == 42)
    #expect(limits.primaryWindow?.remainingPercent == 58)
    #expect(limits.secondaryWindow?.remainingPercent == 95)
    #expect(limits.spendLimit?.remaining == "17000")
    #expect(limits.spendLimit?.remainingPercent == 68)
    #expect(limits.resetCreditsAvailableCount == 3)
    #expect(await transport.requests.first?.url?.path == "/backend-api/wham/usage")
  }

  @Test func rateLimitsAcceptExplicitlyUnavailableOptionalSections() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let transport = FixtureTransport([
      .json(
        200,
        [
          "plan_type": "plus",
          "rate_limit": NSNull(),
          "rate_limit_reached_type": NSNull(),
          "spend_control": NSNull(),
          "additional_rate_limits": NSNull(),
          "rate_limit_reset_credits": NSNull(),
        ])
    ])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let text = ChatGPTTextSession(account: session)

    let limits = try await text.rateLimits()

    #expect(limits.planType == "plus")
    #expect(limits.primaryWindow == nil)
    #expect(limits.secondaryWindow == nil)
    #expect(limits.spendLimit == nil)
    #expect(limits.additionalRateLimits.isEmpty)
  }

  @Test func exactLunaModelIsWrittenToTheSubscriptionRequestBody() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let sse = """
      data: {"type":"response.output_text.delta","delta":"ok"}

      data: {"type":"response.completed","response":{"id":"response-1","output":[]}}

      """
    let transport = FixtureTransport([.sse(200, sse)])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: generationCatalogTransport())
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-5.6-luna"), transport: transport)
    let request = ModelRequest(
      sessionID: "exact-luna", messages: [.init(role: .user, content: "hello")],
      tools: [])

    let output = try await client.generate(request: request)
    #expect(output.content == "ok")
    let requests = await transport.requests
    let body = try #require(requests.first?.httpBody)
    let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(root["model"] as? String == "gpt-5.6-luna")
  }

  @Test func unauthorizedGenerationRefreshesOnceThenSucceeds() async throws {
    let stale = tokenSet(expiration: Date().addingTimeInterval(3_600), access: "stale.access.token")
    let store = MemoryCredentialStore(tokenResponse: stale)
    let sse = """
      data: {"type":"response.output_text.delta","delta":"ok"}

      data: {"type":"response.completed","response":{"id":"response-1","output":[]}}

      """
    let transport = FixtureTransport([
      generationCatalogReply(),
      .response(401),
      .data(
        200,
        tokenResponse(expiration: Date().addingTimeInterval(7_200), access: "fresh.access.token")),
      .sse(200, sse),
    ])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
    let request = ModelRequest(
      sessionID: "refresh-proof",
      messages: [.init(role: .user, content: "hello")],
      tools: [])
    let output = try await client.generate(request: request)
    #expect(output.content == "ok")
    #expect(try store.load()?.accessToken == "fresh.access.token")
    #expect(await transport.requests.count == 4)
  }

  @Test func noCredentialFailsWithoutNetworkOrFallback() async throws {
    let transport = FixtureTransport([])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)
    let client = try ChatGPTModelClient(account: session, transport: transport)
    let request = ModelRequest(
      sessionID: "signed-out",
      messages: [.init(role: .user, content: "hello")],
      tools: [])
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await client.generate(request: request)
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func reasoningItemsAndAuthoritativeMessageSeedProduceOneTextResult() async throws {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let sse = """
      data: {"type":"response.output_item.added","item":{"id":"reasoning-1","type":"reasoning","summary":[]}}

      data: {"type":"response.output_item.done","item":{"id":"reasoning-1","type":"reasoning","summary":[]}}

      data: {"type":"response.output_item.added","item":{"id":"message-1","type":"message","content":[{"type":"output_text","text":"authoritative"}]}}

      data: {"type":"response.output_item.done","item":{"id":"message-1","type":"message","content":[{"type":"output_text","text":"authoritative"}]}}

      data: {"type":"response.completed","response":{"id":"response-1","output":[{"id":"message-1","type":"message","content":[{"type":"output_text","text":"authoritative"}]}]}}

      """
    let transport = FixtureTransport([.sse(200, sse)])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: generationCatalogTransport())
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
    let request = ModelRequest(
      sessionID: "reasoning-seed",
      messages: [.init(role: .user, content: "hello")], tools: [])
    let output = try await client.generate(request: request)
    #expect(output.content == "authoritative")
  }

  @Test func largeProviderDeltaIsRechunkedWithoutTextLoss() async throws {
    let text = String(repeating: "한글A", count: 1_500)
    let escaped = try String(
      decoding: JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
      as: UTF8.self)
    let sse = """
      data: {"type":"response.output_text.delta","delta":\(escaped)}

      data: {"type":"response.completed","response":{"id":"response-1","output":[]}}

      """
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let transport = FixtureTransport([.sse(200, sse)])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: generationCatalogTransport())
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
    let request = ModelRequest(
      sessionID: "large-delta", messages: [.init(role: .user, content: "hello")],
      tools: [])
    let output = try await client.generate(request: request)
    #expect(output.content == text)
  }

  @Test func sseParserAcceptsEveryPairOfValidLineEndings() throws {
    let endings: [(String, String)] = [
      ("\n", "\n"), ("\r\n", "\r\n"), ("\n", "\r\n"),
      ("\r\n", "\r"), ("\n", "\r"),
      ("\r", "\r"), ("\r", "\r\n"), ("\r\n", "\n"),
    ]

    for (first, second) in endings {
      var parser = try ChatGPTSSEParser(maxEventBytes: 256, maxEvents: 4)
      let body = "event: message\(first)data: first\(first)\(second)data: second\(first)\(second)"
      let events = try parser.feed(Data(body.utf8), finish: true)
      #expect(
        events == [
          ChatGPTSSEEvent(data: "first"),
          ChatGPTSSEEvent(data: "second"),
        ], "line endings: \(first.debugDescription) + \(second.debugDescription)")
    }
  }

  @Test func sseParserWaitsForFragmentedCarriageReturnBeforeFindingBoundary() throws {
    let endings: [(String, String)] = [
      ("\n", "\n"), ("\r\n", "\r\n"), ("\n", "\r\n"),
      ("\r\n", "\r"), ("\n", "\r"),
      ("\r", "\r"), ("\r", "\r\n"), ("\r\n", "\n"),
    ]

    for (first, second) in endings {
      var parser = try ChatGPTSSEParser(maxEventBytes: 256, maxEvents: 4)
      let body = Data("data: first\(first)\(second)data: second\(first)\(second)".utf8)
      var events: [ChatGPTSSEEvent] = []
      for byte in body {
        events.append(contentsOf: try parser.feed(Data([byte])))
      }
      events.append(contentsOf: try parser.feed(Data(), finish: true))
      #expect(
        events == [
          ChatGPTSSEEvent(data: "first"),
          ChatGPTSSEEvent(data: "second"),
        ], "line endings: \(first.debugDescription) + \(second.debugDescription)")
    }
  }

  @Test func sseParserStripsLeadingBOMAndDiscardsIncompleteEOFEvent() throws {
    var bomParser = try ChatGPTSSEParser(maxEventBytes: 256, maxEvents: 4)
    let payload = Data([0xEF, 0xBB, 0xBF]) + Data("data: bom\n\n".utf8)
    var events: [ChatGPTSSEEvent] = []
    for byte in payload {
      events.append(contentsOf: try bomParser.feed(Data([byte])))
    }
    events.append(contentsOf: try bomParser.feed(Data(), finish: true))
    #expect(events == [ChatGPTSSEEvent(data: "bom")])

    var incompleteParser = try ChatGPTSSEParser(maxEventBytes: 256, maxEvents: 4)
    #expect(try incompleteParser.feed(Data("data: incomplete\n".utf8), finish: true).isEmpty)
  }

  @Test func sseParserDoesNotEmitEventsWithoutData() throws {
    var parser = try ChatGPTSSEParser(maxEventBytes: 256, maxEvents: 4)
    let events = try parser.feed(Data(": keepalive\n\nunknown: value\n\n".utf8), finish: true)
    #expect(events.isEmpty)
  }

  @Test func transientRefreshFailureRetainsCredentialAndIsNotReportedAsSignInRequired() async throws
  {
    let stale = tokenSet(expiration: Date().addingTimeInterval(-60))
    let store = MemoryCredentialStore(tokenResponse: stale)
    let transport = FixtureTransport([.response(503)])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
    let request = ModelRequest(
      sessionID: "transient-refresh", messages: [.init(role: .user, content: "hello")],
      tools: [])
    do {
      _ = try await client.generate(request: request)
      Issue.record("Expected a transient source failure.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .sourceUnavailable)
    }
    #expect(try store.load()?.refreshToken == stale.refreshToken)
  }

  @Test func sequentialMessageItemsAreConcatenatedAndDuplicateLifecycleFailsClosed() async throws {
    let valid = """
      data: {"type":"response.output_item.added","item":{"id":"message-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"one"}]}}

      data: {"type":"response.output_item.done","item":{"id":"message-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"one"}]}}

      data: {"type":"response.output_item.added","item":{"id":"message-2","type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]}}

      data: {"type":"response.output_item.done","item":{"id":"message-2","type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]}}

      data: {"type":"response.completed","response":{"id":"response-1","output":[{"id":"message-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"one"}]},{"id":"message-2","type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]}]}}

      """
    let output = try await collectFixture(valid)
    #expect(output.content == "onetwo")

    let duplicate = """
      data: {"type":"response.output_item.added","item":{"id":"message-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"one"}]}}

      data: {"type":"response.output_item.done","item":{"id":"message-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"one"}]}}

      data: {"type":"response.output_item.done","item":{"id":"message-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"one"}]}}

      """
    await #expect(throws: ModelGenerationFailure.self) { _ = try await collectFixture(duplicate) }
  }

  @Test func cancellingAccountSignInCancelsAnInFlightTransportWait() async throws {
    let transport = StallingTransport()
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)
    let authorization = try await session.beginSignIn()
    let task = Task { try await session.completeSignIn(authorization) }
    let state = try authorizationState(authorization)
    let (_, response) = try await sendCallback(
      authorization, code: "authorization-1", state: state)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    while !(await transport.started) { try await Task.sleep(for: .milliseconds(5)) }
    try await session.cancelSignIn()
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: (any Error).self) { _ = try await task.value }
    #expect(start.duration(to: clock.now) < .seconds(1))
  }

  @Test func cancellingAccountSignInDuringTransportCreationPreservesCancellation() async throws {
    let transport = CancellationAwareTransport()
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)
    let authorization = try await session.beginSignIn()
    let completion = Task { try await session.completeSignIn(authorization) }
    let state = try authorizationState(authorization)
    let (_, response) = try await sendCallback(
      authorization, code: "authorization-cancelled", state: state)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    while !(await transport.started) { try await Task.sleep(for: .milliseconds(5)) }

    try await session.cancelSignIn()
    await #expect(throws: CancellationError.self) { _ = try await completion.value }
    #expect(try await session.status() == .signedOut)
  }

  @Test func cancellingOneRefreshWaiterDoesNotCancelTheSharedRefresh() async throws {
    let stale = tokenSet(expiration: Date().addingTimeInterval(-60))
    let store = MemoryCredentialStore(tokenResponse: stale)
    let transport = ControlledTransport()
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)

    let first = Task { try await session.access(forceRefresh: true) }
    while !(await transport.started) { try await Task.sleep(for: .milliseconds(5)) }
    let second = Task { try await session.access(forceRefresh: true) }
    second.cancel()
    await #expect(throws: CancellationError.self) { _ = try await second.value }

    await transport.finish(
      status: 200,
      body: tokenResponse(
        expiration: Date().addingTimeInterval(3_600), access: "fresh.access.token"))
    let refreshed = try await first.value
    #expect(refreshed.accessToken == "fresh.access.token")
    #expect(await transport.requestCount == 1)
  }

  @Test func permanentRefreshFailureDoesNotPoisonAReauthenticatedSession() async throws {
    let stale = tokenSet(expiration: Date().addingTimeInterval(-60))
    let store = MemoryCredentialStore(tokenResponse: stale)
    let transport = FixtureTransport([
      .response(401),
      .data(
        200, tokenResponse(expiration: Date().addingTimeInterval(3_600), access: "new.access.token")
      ),
      .data(
        200,
        tokenResponse(expiration: Date().addingTimeInterval(7_200), access: "renewed.access.token")),
    ])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)

    await #expect(throws: ChatGPTFailure.self) {
      _ = try await session.access(forceRefresh: true)
    }
    let authorization = try await session.beginSignIn()
    let completion = Task { try await session.completeSignIn(authorization) }
    let state = try authorizationState(authorization)
    let (_, response) = try await sendCallback(
      authorization, code: "authorization-2", state: state)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    _ = try await completion.value
    let refreshed = try await session.access(forceRefresh: true)

    #expect(refreshed.accessToken == "renewed.access.token")
    #expect(await transport.requests.count == 3)
  }

  @Test func successfulOAuthInvalidatesAnInFlightRefreshBeforeCredentialCommit() async throws {
    let stale = tokenSet(expiration: Date().addingTimeInterval(-60), access: "stale.access.token")
    let store = MemoryCredentialStore(tokenResponse: stale)
    let transport = RefreshEpochTransport()
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)

    let refresh = Task { try await session.access(forceRefresh: true) }
    while !(await transport.refreshStarted) { try await Task.sleep(for: .milliseconds(5)) }

    let authorization = try await session.beginSignIn()
    let completion = Task { try await session.completeSignIn(authorization) }
    let state = try authorizationState(authorization)
    let (_, response) = try await sendCallback(
      authorization, code: "authorization-epoch", state: state)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    _ = try await completion.value
    #expect(try store.load()?.accessToken == "oauth.access.token")

    await transport.releaseRefresh()
    await #expect(throws: (any Error).self) { _ = try await refresh.value }
    #expect(try store.load()?.accessToken == "oauth.access.token")
  }

  @Test func cancellingTheOnlySignInWaiterPreventsCredentialCommit() async throws {
    let store = MemoryCredentialStore()
    let transport = SignInCancellationTransport()
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let authorization = try await session.beginSignIn()
    let completion = Task { try await session.completeSignIn(authorization) }
    let state = try authorizationState(authorization)
    let (_, response) = try await sendCallback(
      authorization, code: "authorization-cancelled", state: state)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    while !(await transport.pollStarted) { try await Task.sleep(for: .milliseconds(5)) }

    try await session.cancelSignIn()
    await #expect(throws: (any Error).self) { _ = try await completion.value }
    await transport.releasePoll()
    try await Task.sleep(for: .milliseconds(50))

    #expect(try store.load() == nil)
    #expect(await transport.requestCount == 1)
  }

  @Test func terminalResponseRequiresAnAuthoritativeResponseID() async throws {
    let malformed = """
      data: {"type":"response.output_text.delta","delta":"looks valid"}

      data: {"type":"response.completed","response":{"output":[]}}

      """
    await #expect(throws: ModelGenerationFailure.self) { _ = try await collectFixture(malformed) }
  }

  @Test func duplicateMessageAddedLifecycleFailsClosed() async throws {
    let duplicate = """
      data: {"type":"response.output_item.added","item":{"id":"message-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"one"}]}}

      data: {"type":"response.output_item.added","item":{"id":"message-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"one"}]}}

      """
    await #expect(throws: ModelGenerationFailure.self) { _ = try await collectFixture(duplicate) }
  }

  @Test func modelClientGeneratesAndStreamsText() async throws {
    let sse = """
      data: {"type":"response.output_text.delta","delta":"hello"}

      data: {"type":"response.completed","response":{"id":"response-1","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}

      """
    let client = try makeModelClient(sse)
    let request = ModelRequest(sessionID: "model-test", messages: [.init(role: .user, content: "hi")], tools: [])
    #expect(try await client.generate(request: request).content == "hello")
    var events: [ModelEvent] = []
    for try await event in client.stream(request: request) { events.append(event) }
    #expect(events.contains(.textDelta("hello")))
    #expect(events.contains { if case .completed(let turn) = $0 { return turn.content == "hello" }; return false })
  }

  @Test func modelClientMapsStructuredSchemaAndRejectsCapabilitiesBeforeTransport() async throws {
    let sse = """
      data: {"type":"response.output_text.delta","delta":"{\\"ok\\":true}"}

      data: {"type":"response.completed","response":{"id":"response-schema","output":[]}}

      """
    let transport = FixtureTransport([.sse(200, sse)])
    let store = MemoryCredentialStore(tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(profile: .codexSubscription, store: store, transport: generationCatalogTransport())
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
    let schema: JSONValue = .object(["type": .string("object")])
    let request = ModelRequest(
      sessionID: "schema-test",
      messages: [.init(role: .user, content: "hi")],
      tools: [],
      outputFormat: .jsonObject(schema: schema))
    #expect(try await client.generate(request: request).content == "{\"ok\":true}")
    let generation = try #require(await transport.requests.first)
    let body = try #require(generation.httpBody)
    let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let text = try #require(root["text"] as? [String: Any])
    let format = try #require(text["format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")

    let mediaTransport = FixtureTransport([])
    let mediaSession = ChatGPTAccountSession(profile: .codexSubscription, store: MemoryCredentialStore(tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600))), transport: mediaTransport)
    let mediaClient = try ChatGPTModelClient(
      account: mediaSession, model: .exact("gpt-subscription"), transport: mediaTransport)
    let media = AgentMessage(role: .user, contentParts: [.image(ModelBinaryContent(mimeType: "image/png", data: Data([1])))])
    let unsupported = ModelRequest(sessionID: "media-test", messages: [media], tools: [])
    await #expect(throws: ModelGenerationFailure.self) {
      _ = try await mediaClient.generate(request: unsupported)
    }
    #expect(await mediaTransport.requests.isEmpty)
  }

  @Test func imageProtocolProfileMatchesCodexRust01610Provenance() {
    let profile = ChatGPTProtocolProfile.codexSubscription
    #expect(profile.clientVersion == "0.161.0")
    #expect(
      profile.sourceRevision
        == "openai/codex:rust-v0.161.0@979011409de0a60b52f179721948e65531d26144")
    #expect(
      profile.imageGenerationsEndpoint.absoluteString
        == "https://chatgpt.com/backend-api/codex/images/generations")
    #expect(
      profile.imageEditsEndpoint.absoluteString
        == "https://chatgpt.com/backend-api/codex/images/edits")
    #expect(ChatGPTImageClient.model == "gpt-image-2")
    #expect(ChatGPTImageClient.maximumEditImages == 5)
    #expect(ChatGPTImageClient.maximumInputImageBytes == 50 * 1_024 * 1_024)
    #expect(ChatGPTImageClient.maximumImageBytes == 32 * 1_024 * 1_024)
    #expect(ChatGPTImageClient.defaultMaximumRequestBytes == 96 * 1_024 * 1_024)
    #expect(ChatGPTImageClient.maximumEditRequestBytes == 336 * 1_024 * 1_024)
    #expect(ChatGPTImageClient.defaultMaximumResponseBytes == 48 * 1_024 * 1_024)

    let maximumEncodedInput =
      ((ChatGPTImageClient.maximumInputImageBytes + 2) / 3) * 4
    #expect(
      ChatGPTImageClient.defaultMaximumRequestBytes
        > maximumEncodedInput + 1_024)
    #expect(
      ChatGPTImageClient.maximumEditRequestBytes
        > maximumEncodedInput * ChatGPTImageClient.maximumEditImages + 1_024)
  }

  @Test func explicitImageGenerationUsesAuthoritativeWireShapeAndReturnsPNG() async throws {
    let transport = FixtureTransport([.dataWithHeaders(200, ["x-codex-imagegen-request-id": "imgreq-1"], imageResponse())])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)
    let turnID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    let result = try await client.generate(.init(
      prompt: "a red fox in a field", background: .opaque, quality: .medium,
      size: "1024x1536", turnID: turnID))

    #expect(result.image.mimeType == "image/png")
    #expect(result.image.data == fixturePNG())
    #expect(result.background == .opaque)
    #expect(result.quality == .medium)
    #expect(result.size == "1024x1536")
    #expect(result.imageGenerationRequestID == "imgreq-1")
    let request = try #require(await transport.requests.first)
    #expect(request.url == ChatGPTProtocolProfile.codexSubscription.imageGenerationsEndpoint)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer header.payload.signature")
    #expect(request.value(forHTTPHeaderField: "Chatgpt-Account-Id") == "account-1")
    #expect(request.value(forHTTPHeaderField: "Version") == "0.161.0")
    #expect(request.value(forHTTPHeaderField: "Originator") == "codex_cli_rs")
    #expect(
      request.value(forHTTPHeaderField: "x-codex-image-turn-id")
        == "00000000-0000-4000-8000-000000000001")
    #if os(macOS)
      #expect(request.value(forHTTPHeaderField: "User-Agent") == "codex_cli_rs/0.161.0 (macOS; arm64)")
    #endif
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((object["prompt"] as? String)?.hasPrefix("a red fox in a field") == true)
    #expect((object["prompt"] as? String)?.contains("fully opaque PNG background") == true)
    #expect(object["background"] as? String == "auto")
    #expect(object["model"] as? String == "gpt-image-2")
    #expect(object["quality"] as? String == "medium")
    #expect(object["size"] as? String == "1024x1536")
    #expect(object["n"] == nil)
  }

  @Test func imageResponsePreservesOpaqueCodexSizeMetadata() async throws {
    let transport = FixtureTransport([.data(200, imageResponse(size: "1254x1254"))])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)

    let result = try await client.generate(.init(prompt: "test"))

    #expect(result.image.data == fixturePNG())
    #expect(result.size == "1254x1254")
  }

  @Test func imageResponseIgnoresUnknownOptionalMetadata() async throws {
    let transport = FixtureTransport([
      .data(200, imageResponse(background: "future-background", quality: "ultra-v2"))
    ])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)

    let result = try await client.generate(.init(prompt: "test"))

    #expect(result.image.data == fixturePNG())
    #expect(result.background == nil)
    #expect(result.quality == nil)
  }

  @Test func imageResponseIgnoresNonStringOptionalMetadata() async throws {
    let encoded = fixturePNG().base64EncodedString()
    let response = Data(
      """
      {"created":1778832973,"data":[{"b64_json":"\(encoded)"}],
       "background":{"future":true},"quality":7,"size":[1254,1254]}
      """.utf8)
    let transport = FixtureTransport([.data(200, response)])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)

    let result = try await client.generate(.init(prompt: "test"))

    #expect(result.image.data == fixturePNG())
    #expect(result.background == nil)
    #expect(result.quality == nil)
    #expect(result.size == nil)
  }

  @Test func imageResponseUsesFirstBoundedValidPNGFromMultipleItems() async throws {
    let transport = FixtureTransport([
      .data(200, imageResponse(items: [
        "not base64",
        Data("not a png".utf8).base64EncodedString(),
        fixturePNG().base64EncodedString(),
      ]))
    ])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)

    let result = try await client.generate(.init(prompt: "test"))

    #expect(result.image.data == fixturePNG())
  }

  @Test func imageResponseAcceptsArbitraryUInt64CreatedMetadata() async throws {
    let encoded = fixturePNG().base64EncodedString()
    let response = Data(
      "{\"created\":18446744073709551615,\"data\":[{\"b64_json\":\"\(encoded)\"}]}".utf8)
    let transport = FixtureTransport([.data(200, response)])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)

    let result = try await client.generate(.init(prompt: "test"))

    #expect(result.image.data == fixturePNG())
    #expect(result.createdAt.timeIntervalSince1970 == TimeInterval(UInt64.max))
  }

  @Test func imageResponseIgnoresUnusedLargeHeaderSet() async throws {
    let headers = Dictionary(uniqueKeysWithValues: (0..<257).map { ("x-fixture-\($0)", "value") })
    let transport = FixtureTransport([
      .dataWithHeaders(200, headers, imageResponse())
    ])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)

    let result = try await client.generate(.init(prompt: "test"))

    #expect(result.image.data == fixturePNG())
  }

  @Test func imageResponseTrimsBase64EdgeWhitespace() async throws {
    let paddedBase64 = "\n  \(fixturePNG().base64EncodedString())\t"
    let transport = FixtureTransport([.data(200, imageResponse(base64: paddedBase64))])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)

    let result = try await client.generate(.init(prompt: "test"))

    #expect(result.image.data == fixturePNG())
  }

  @Test func imageResponseTrimsOnlyRustUnicodeWhitespaceAtEdges() async throws {
    let base64 = fixturePNG().base64EncodedString()
    let accepted = "\u{00A0}\(base64)\u{00A0}"
    let acceptedTransport = FixtureTransport([.data(200, imageResponse(base64: accepted))])
    let acceptedStore = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let acceptedSession = ChatGPTAccountSession(
      profile: .codexSubscription, store: acceptedStore, transport: acceptedTransport)
    let acceptedClient = try ChatGPTImageClient(
      account: acceptedSession, transport: acceptedTransport)

    let result = try await acceptedClient.generate(.init(prompt: "test"))
    #expect(result.image.data == fixturePNG())

    let rejected = [
      "\u{200B}\(base64)",
      "\(base64.prefix(4)) \(base64.dropFirst(4))",
      "\(base64.prefix(4))\u{00A0}\(base64.dropFirst(4))",
    ]
    for encoded in rejected {
      let transport = FixtureTransport([.data(200, imageResponse(base64: encoded))])
      let store = MemoryCredentialStore(
        tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
      let session = ChatGPTAccountSession(
        profile: .codexSubscription, store: store, transport: transport)
      let client = try ChatGPTImageClient(account: session, transport: transport)
      do {
        _ = try await client.generate(.init(prompt: "test"))
        Issue.record("non-edge Rust whitespace or U+200B must be rejected")
      } catch let failure as ChatGPTImageFailure {
        #expect(failure.code == .malformedResponse)
      }
    }
  }

  @Test func imageResponseAcceptsEveryPinnedCodexEdgeWhitespaceScalar() async throws {
    let base64 = fixturePNG().base64EncodedString()
    #expect(ChatGPTImageWireCodec.codexBase64EdgeWhitespaceScalars.count == 25)

    for value in ChatGPTImageWireCodec.codexBase64EdgeWhitespaceScalars {
      let scalar = try #require(Unicode.Scalar(value))
      let transport = FixtureTransport([
        .data(200, imageResponse(base64: "\(scalar)\(base64)\(scalar)"))
      ])
      let store = MemoryCredentialStore(
        tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
      let session = ChatGPTAccountSession(
        profile: .codexSubscription, store: store, transport: transport)
      let client = try ChatGPTImageClient(account: session, transport: transport)

      let result = try await client.generate(.init(prompt: "test"))
      #expect(result.image.data == fixturePNG())
    }
  }

  @Test func explicitImageEditSendsBoundedPNGDataURLs() async throws {
    let transport = FixtureTransport([.data(200, imageResponse())])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)
    let input = ChatGPTImageContent(mimeType: "image/png", data: fixturePNG())
    let turnID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    _ = try await client.edit(.init(images: [input], prompt: "add a red hat", turnID: turnID))

    let request = try #require(await transport.requests.first)
    #expect(request.url == ChatGPTProtocolProfile.codexSubscription.imageEditsEndpoint)
    #expect(
      request.value(forHTTPHeaderField: "x-codex-image-turn-id")
        == "00000000-0000-4000-8000-000000000002")
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let images = try #require(object["images"] as? [[String: String]])
    #expect(images == [["image_url": "data:image/png;base64,\(fixturePNG().base64EncodedString())"]])
    #expect(object["prompt"] as? String == "add a red hat")
    #expect(object["background"] as? String == "auto")
    #expect(object["quality"] as? String == "auto")
    #expect(object["size"] as? String == "auto")
  }

  @Test func imageEditDefaultBudgetAcceptsFiveTypicalPNGs() async throws {
    let transport = FixtureTransport([.data(200, imageResponse())])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)
    let image = ChatGPTImageContent(mimeType: "image/png", data: fixturePNG())

    _ = try await client.edit(.init(images: Array(repeating: image, count: 5), prompt: "edit"))

    let request = try #require(await transport.requests.first)
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((object["images"] as? [[String: String]])?.count == 5)
  }

  @Test func imageInputValidationFailsBeforeCredentialsOrTransport() async throws {
    let transport = FixtureTransport([])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)
    await #expect(throws: ChatGPTImageFailure.self) {
      _ = try await client.generate(.init(prompt: ""))
    }
    await #expect(throws: ChatGPTImageFailure.self) {
      _ = try await client.edit(.init(
        images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))], prompt: "edit"))
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func imageGenerationAcceptsOfficialBoundedFlexibleSize() async throws {
    let transport = FixtureTransport([.data(200, imageResponse())])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)

    _ = try await client.generate(.init(prompt: "test", size: "2048x1152"))

    let request = try #require(await transport.requests.first)
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["size"] as? String == "2048x1152")
  }

  @Test func imageGenerationRejectsMalformedOrUnsafeFlexibleSizesBeforeAuth() async throws {
    let rejected = [
      "2048X1152", "2048x", "2048x1153", "4096x1024", "3840x1024", "640x640",
      "+2048x1152", "2048 x1152",
    ]
    for size in rejected {
      let transport = FixtureTransport([])
      let session = ChatGPTAccountSession(
        profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)
      let client = try ChatGPTImageClient(account: session, transport: transport)
      do {
        _ = try await client.generate(.init(prompt: "test", size: size))
        Issue.record("unsafe or malformed image size must fail: \(size)")
      } catch let failure as ChatGPTImageFailure {
        #expect(failure.code == .invalidRequest)
      }
      #expect(await transport.requests.isEmpty)
    }
  }

  @Test func imageEditRejectsAggregateBase64ExpansionBeforeTransport() async throws {
    let transport = FixtureTransport([])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)
    let client = try ChatGPTImageClient(
      account: session, transport: transport, maxRequestBytes: 1 * 1_024 * 1_024)
    let large = ChatGPTImageContent(
      mimeType: "image/png", data: Data(repeating: 0, count: 256 * 1_024))
    do {
      _ = try await client.edit(.init(images: Array(repeating: large, count: 5), prompt: "edit"))
      Issue.record("aggregate base64 expansion must fail")
    } catch let failure as ChatGPTImageFailure {
      #expect(failure.code == .limitExceeded)
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func imageClientAcceptsExplicitFullFiveImageRequestBudget() throws {
    let transport = FixtureTransport([])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: MemoryCredentialStore(), transport: transport)

    _ = try ChatGPTImageClient(
      account: session,
      transport: transport,
      maxRequestBytes: ChatGPTImageClient.maximumEditRequestBytes)
  }

  @Test func imageResponseRejectsPNGDecompressionBombDimensions() async throws {
    var bomb = fixturePNG()
    bomb.replaceSubrange(16..<20, with: [0, 0, 0x40, 0])
    bomb.replaceSubrange(20..<24, with: [0, 0, 0x40, 0])
    let transport = FixtureTransport([
      .data(200, imageResponse(base64: bomb.base64EncodedString()))
    ])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)
    await #expect(throws: ChatGPTImageFailure.self) {
      _ = try await client.generate(.init(prompt: "test"))
    }
  }

  @Test func imageResponseRejectsPNGDecodedRasterByteBomb() async throws {
    var bomb = fixturePNG()
    bomb.replaceSubrange(16..<20, with: [0, 0, 0x40, 0])
    bomb.replaceSubrange(20..<24, with: [0, 0, 4, 0])
    bomb[24] = 16
    bomb[25] = 6
    let transport = FixtureTransport([
      .data(200, imageResponse(base64: bomb.base64EncodedString()))
    ])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)
    await #expect(throws: ChatGPTImageFailure.self) {
      _ = try await client.generate(.init(prompt: "test"))
    }
  }

  @Test func imageResponseRejectsMalformedJSONBase64PNGAndOversize() async throws {
    let malformed = Data("{}".utf8)
    let badBase64 = imageResponse(base64: "not base64")
    let badPNG = imageResponse(base64: Data("not a png".utf8).base64EncodedString())
    let oversized = Data(repeating: 1, count: 64 * 1_024 + 1)
    for response in [malformed, badBase64, badPNG, oversized] {
      let transport = FixtureTransport([.data(200, response)])
      let store = MemoryCredentialStore(
        tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
      let session = ChatGPTAccountSession(
        profile: .codexSubscription, store: store, transport: transport)
      let client = try ChatGPTImageClient(
        account: session, transport: transport, maxResponseBytes: 64 * 1_024)
      await #expect(throws: ChatGPTImageFailure.self) {
        _ = try await client.generate(.init(prompt: "test"))
      }
    }
  }

  @Test func imageRequestMaps429AndRefreshesOnceAfter401() async throws {
    let rateTransport = FixtureTransport([.response(429)])
    let rateStore = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let rateSession = ChatGPTAccountSession(
      profile: .codexSubscription, store: rateStore, transport: rateTransport)
    let rateClient = try ChatGPTImageClient(account: rateSession, transport: rateTransport)
    do {
      _ = try await rateClient.generate(.init(prompt: "test"))
      Issue.record("429 must fail")
    } catch let failure as ChatGPTImageFailure {
      #expect(failure.code == .rateLimited)
    }

    let refreshTransport = FixtureTransport([
      .response(401),
      .data(200, tokenResponse(
        expiration: Date().addingTimeInterval(3_600), access: "fresh.access.token")),
      .data(200, imageResponse()),
    ])
    let refreshStore = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600), access: "old.token.value"))
    let refreshSession = ChatGPTAccountSession(
      profile: .codexSubscription, store: refreshStore, transport: refreshTransport)
    let refreshClient = try ChatGPTImageClient(
      account: refreshSession, transport: refreshTransport)
    _ = try await refreshClient.generate(.init(prompt: "test"))
    let requests = await refreshTransport.requests
    #expect(requests.count == 3)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer old.token.value")
    #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer fresh.access.token")
    #expect(
      requests[0].value(forHTTPHeaderField: "x-codex-image-turn-id")
        == requests[2].value(forHTTPHeaderField: "x-codex-image-turn-id"))
  }

  @Test func imageRequestMapsServiceRejection() async throws {
    let transport = FixtureTransport([.response(500)])
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)
    do {
      _ = try await client.generate(.init(prompt: "test"))
      Issue.record("500 must fail")
    } catch let failure as ChatGPTImageFailure {
      #expect(failure.code == .serviceRejected)
    }
  }

  @Test func cancellingExplicitImageRequestCancelsTransportCreation() async throws {
    let transport = CancellationAwareTransport()
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: transport)
    let client = try ChatGPTImageClient(account: session, transport: transport)
    let task = Task { try await client.generate(.init(prompt: "test")) }
    while !(await transport.started) { try await Task.sleep(for: .milliseconds(5)) }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("cancelled image request must fail")
    } catch let failure as ChatGPTImageFailure {
      #expect(failure.code == .cancelled)
    }
  }

  private func makeModelClient(_ sse: String) throws -> ChatGPTModelClient {
    let transport = FixtureTransport([.sse(200, sse), .sse(200, sse)])
    let store = MemoryCredentialStore(tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let session = ChatGPTAccountSession(profile: .codexSubscription, store: store, transport: generationCatalogTransport())
    return try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
  }

  private func collectFixture(_ sse: String) async throws -> ModelTurn {
    let store = MemoryCredentialStore(
      tokenResponse: tokenSet(expiration: Date().addingTimeInterval(3_600)))
    let transport = FixtureTransport([.sse(200, sse)])
    let session = ChatGPTAccountSession(
      profile: .codexSubscription, store: store, transport: generationCatalogTransport())
    let client = try ChatGPTModelClient(
      account: session, model: .exact("gpt-subscription"), transport: transport)
    let request = ModelRequest(
      sessionID: UUID().uuidString,
      messages: [.init(role: .user, content: "hello")], tools: [])
    return try await client.generate(request: request)
  }
}

private func authorizationState(_ authorization: ChatGPTWebAuthorization) throws -> String {
  try #require(
    URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "state" })?.value)
}

private func sendCallback(
  _ authorization: ChatGPTWebAuthorization,
  code: String,
  state: String
) async throws -> (Data, URLResponse) {
  var components = try #require(
    URLComponents(url: authorization.redirectURI, resolvingAgainstBaseURL: false))
  let host = try #require(authorization.redirectURI.host)
  let port = try #require(authorization.redirectURI.port)
  components.host = "127.0.0.1"
  components.queryItems = [
    URLQueryItem(name: "code", value: code),
    URLQueryItem(name: "state", value: state),
  ]
  let callback = try #require(components.url)
  var request = URLRequest(url: callback)
  request.setValue("\(host):\(port)", forHTTPHeaderField: "Host")
  request.timeoutInterval = 5
  return try await URLSession.shared.data(for: request)
}

private final class MemoryCredentialStore: ChatGPTCredentialStoring, Sendable {
  private let storage: OSAllocatedUnfairLock<ChatGPTTokenSet?>
  init(tokenResponse: ChatGPTTokenSet? = nil) {
    storage = OSAllocatedUnfairLock(initialState: tokenResponse)
  }
  func load() throws -> ChatGPTTokenSet? { storage.withLock { $0 } }
  func save(_ value: ChatGPTTokenSet) throws { storage.withLock { $0 = value } }
  func delete() throws { storage.withLock { $0 = nil } }
}

private actor FixtureTransport: ChatGPTTransport {
  enum Reply: Sendable {
    case data(Int, Data)
    case dataWithHeaders(Int, [String: String], Data)
    case response(Int)
    case sse(Int, String)
    static func json(_ status: Int, _ object: Any) -> Reply {
      .data(status, try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
  }

  private var replies: [Reply]
  private(set) var requests: [URLRequest] = []
  init(_ replies: [Reply]) { self.replies = replies }

  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error>
  {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }

  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation
  {
    requests.append(request)
    guard !replies.isEmpty else { throw ChatGPTFailure(.transportFailure) }
    let reply = replies.removeFirst()
    return FixtureTransportResponse.completed { continuation in
      switch reply {
      case .data(let status, let data):
        continuation.yield(.response(statusCode: status, headers: [:]))
        if !data.isEmpty { continuation.yield(.body(data)) }
      case .dataWithHeaders(let status, let headers, let data):
        continuation.yield(.response(statusCode: status, headers: headers))
        if !data.isEmpty { continuation.yield(.body(data)) }
      case .response(let status):
        continuation.yield(.response(statusCode: status, headers: [:]))
      case .sse(let status, let value):
        continuation.yield(
          .response(statusCode: status, headers: ["content-type": "text/event-stream"]))
        let body =
          value.hasSuffix("\n\n") || value.hasSuffix("\r\r")
            || value.hasSuffix("\r\n\r\n") ? value : value + "\n"
        continuation.yield(.body(Data(body.utf8)))
      }
      continuation.finish()
    }
  }
}

private actor StallingTransport: ChatGPTTransport {
  private(set) var started = false
  private var continuation: FixtureTransportResponse?

  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error>
  {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }

  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation
  {
    started = true
    let response = FixtureTransportResponse()
    continuation = response
    return response.invocation
  }
}

private actor CancellationAwareTransport: ChatGPTTransport {
  private(set) var started = false

  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error>
  {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }

  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation
  {
    started = true
    try await Task.sleep(for: .seconds(30))
    return FixtureTransportResponse.completed { continuation in
      continuation.finish()
    }
  }
}

private actor ControlledTransport: ChatGPTTransport {
  private(set) var started = false
  private(set) var requestCount = 0
  private var continuation: FixtureTransportResponse?

  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error>
  {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }

  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation
  {
    requestCount += 1
    started = true
    let response = FixtureTransportResponse()
    continuation = response
    return response.invocation
  }

  func finish(status: Int, body: Data) {
    continuation?.yield(.response(statusCode: status, headers: [:]))
    continuation?.yield(.body(body))
    continuation?.finish()
    continuation = nil
  }
}

private actor RefreshEpochTransport: ChatGPTTransport {
  private(set) var refreshStarted = false
  private var refreshContinuation:
    FixtureTransportResponse?

  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error>
  {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }

  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation
  {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    if body.contains("\"grant_type\":\"refresh_token\"") {
      refreshStarted = true
      let response = FixtureTransportResponse()
      refreshContinuation = response
      return response.invocation
    }
    let data = tokenResponse(
      expiration: Date().addingTimeInterval(3_600), access: "oauth.access.token")
    return FixtureTransportResponse.completed { continuation in
      continuation.yield(.response(statusCode: 200, headers: [:]))
      continuation.yield(.body(data))
      continuation.finish()
    }
  }

  func releaseRefresh() {
    let data = tokenResponse(
      expiration: Date().addingTimeInterval(7_200), access: "late.refresh.access.token")
    refreshContinuation?.yield(.response(statusCode: 200, headers: [:]))
    refreshContinuation?.yield(.body(data))
    refreshContinuation?.finish()
    refreshContinuation = nil
  }
}

private actor SignInCancellationTransport: ChatGPTTransport {
  private(set) var pollStarted = false
  private(set) var requestCount = 0
  private var pollContinuation:
    FixtureTransportResponse?

  func stream(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> AsyncThrowingStream<ChatGPTTransportElement, any Error>
  {
    try await invocation(request, maxResponseBytes: maxResponseBytes).events
  }

  func invocation(_ request: URLRequest, maxResponseBytes: Int) async throws
    -> ChatGPTTransportInvocation
  {
    requestCount += 1
    if requestCount == 1 {
      pollStarted = true
      let response = FixtureTransportResponse()
      pollContinuation = response
      return response.invocation
    }
    Issue.record("Token exchange ran after the only sign-in waiter was cancelled.")
    return FixtureTransportResponse.completed { continuation in
      continuation.finish(throwing: ChatGPTFailure(.transportFailure))
    }
  }

  func releasePoll() {
    let data = tokenResponse(expiration: Date().addingTimeInterval(3_600))
    pollContinuation?.yield(.response(statusCode: 200, headers: [:]))
    pollContinuation?.yield(.body(data))
    pollContinuation?.finish()
    pollContinuation = nil
  }
}

// A manual test producer. Its completion port joins the writer's explicit finish/cancel;
// this is fixture ordering evidence, never a claim about a live URLSession or account.
private final class FixtureTransportResponse: @unchecked Sendable {
  private enum State { case writing, finishing, settled }
  private let lock = NSLock()
  private var state: State = .writing
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let events: AsyncThrowingStream<ChatGPTTransportElement, any Error>
  private let continuation: AsyncThrowingStream<ChatGPTTransportElement, any Error>.Continuation

  init() {
    let pair = AsyncThrowingStream<ChatGPTTransportElement, any Error>.makeStream()
    events = pair.stream
    continuation = pair.continuation
    continuation.onTermination = { [weak self] termination in
      if case .cancelled = termination { self?.finish(throwing: CancellationError()) }
    }
  }

  var invocation: ChatGPTTransportInvocation {
    .init(events: events, cancel: { self.finish(throwing: CancellationError()) },
          waitForCompletion: { await self.wait() })
  }

  static func completed(_ write: (FixtureTransportResponse) -> Void) -> ChatGPTTransportInvocation {
    let response = FixtureTransportResponse()
    write(response)
    return response.invocation
  }

  func yield(_ element: ChatGPTTransportElement) { continuation.yield(element) }

  func finish(throwing error: (any Error)? = nil) {
    lock.lock()
    guard state == .writing else { lock.unlock(); return }
    state = .finishing
    lock.unlock()
    continuation.finish(throwing: error)
    lock.lock()
    state = .settled
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in pending { waiter.resume() }
  }

  private func wait() async {
    await withCheckedContinuation { waiter in
      lock.lock()
      if state == .settled { lock.unlock(); waiter.resume() }
      else { waiters.append(waiter); lock.unlock() }
    }
  }
}

private func tokenSet(
  expiration: Date,
  access: String = "header.payload.signature"
) -> ChatGPTTokenSet {
  ChatGPTTokenSet(
    accessToken: access,
    refreshToken: "refresh-1",
    idToken: makeJWT([
      "https://api.openai.com/auth": [
        "chatgpt_account_id": "account-1",
        "chatgpt_plan_type": "plus",
      ],
      "email": "fixture@example.com",
    ]),
    expiresAt: expiration,
    account: .init(accountID: "account-1", plan: "plus", email: "fixture@example.com")
  )
}

private func tokenResponse(
  expiration: Date,
  access: String? = nil
) -> Data {
  let accessToken = access ?? makeJWT(["exp": Int(expiration.timeIntervalSince1970)])
  return try! JSONSerialization.data(
    withJSONObject: [
      "access_token": accessToken,
      "refresh_token": "refresh-1",
      "id_token": tokenSet(expiration: expiration).idToken,
      "expires_in": 3_600,
    ], options: [.sortedKeys])
}

private func makeJWT(_ payload: [String: Any]) -> String {
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "none"]).base64URL
  let body = try! JSONSerialization.data(withJSONObject: payload).base64URL
  return "\(header).\(body).signature"
}

private func fixturePNG() -> Data {
  Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

private func imageResponse(
  base64: String? = nil,
  size: String = "1024x1536",
  background: String = "opaque",
  quality: String = "medium",
  items: [String]? = nil
) -> Data {
  try! JSONSerialization.data(
    withJSONObject: [
      "created": 1_778_832_973,
      "background": background,
      "data": (items ?? [base64 ?? fixturePNG().base64EncodedString()]).map {
        ["b64_json": $0]
      },
      "output_format": "png",
      "quality": quality,
      "size": size,
    ], options: [.sortedKeys])
}

extension Data {
  fileprivate var base64URL: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

// Generation fixtures must provide catalog evidence separately from Responses events.
private func generationCatalogReply() -> FixtureTransport.Reply {
  .json(200, ["models": [
    ["slug": "gpt-subscription", "visibility": "list"],
    ["slug": "gpt-5.6-luna", "visibility": "list"],
  ]])
}

private func generationCatalogTransport() -> FixtureTransport {
  FixtureTransport([generationCatalogReply()])
}
