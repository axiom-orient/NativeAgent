import ModelArtifactStore
import MLXModelRegistry
import CryptoKit
import Foundation
import MLXLMCommon
import LanguageModelCore
import LanguageModelRuntime
import XCTest

@testable import MLXProvider

final class MLXTextTests: XCTestCase {
  func testGuidedModePreservesSamplingAndToolContracts() throws {
    let schema: LanguageModelCore.JSONValue = .object(["type": "object"])
    let request = ModelRequest(sessionID: "json", messages: [.init(role: .user, content: "JSON")], tools: [], outputFormat: .jsonObject(schema: schema))
    XCTAssertFalse(MLXGuidedOutput.isEligible(request: request, sampling: .default))
    let greedy = MLXSampling(temperature: 0, topP: 1, topK: 0, repetitionPenalty: 1)
    XCTAssertTrue(MLXGuidedOutput.isEligible(request: request, sampling: greedy))
    let tools = ModelRequest(sessionID: "tools", messages: request.messages,
      tools: [.init(name: "read", description: "Read", inputSchema: schema)], outputFormat: request.outputFormat)
    XCTAssertFalse(MLXGuidedOutput.isEligible(request: tools, sampling: greedy))
  }

  func testGrammarSchemaKeepsRequiredFieldOrderAndEscaping() throws {
    let schema: LanguageModelCore.JSONValue = .object(["type": "object", "properties": .object([
      "z\"": .object(["type": "string"]), "a": .object(["type": "string"])]),
      "required": ["z\"", "a"]])
    let text = try MLXGrammarSchema.encode(schema)
    XCTAssertEqual(try JSONDecoder().decode(LanguageModelCore.JSONValue.self, from: Data(text.utf8)), schema)
    XCTAssertTrue(text.contains(#""properties":{"z\"":{"type":"string"},"a":{"type":"string"}}"#))
  }

  private var fixturePayloads: [String: Data] = [:]

  func testChatMapperPreservesCanonicalMultiTurnRoles() throws {
    let request = ModelRequest(
      sessionID: "history",
      messages: [
        .init(id: "system-1", role: .system, content: "system"),
        .init(id: "user-1", role: .user, content: "one"),
        .init(id: "assistant-1", role: .assistant, content: "answer"),
        .init(id: "user-2", role: .user, content: "two"),
      ],
      tools: [])

    let chat = try MLXChatMapper.map(request: request, disablesThinking: false)

    XCTAssertEqual(chat.history.map { $0.role.rawValue }, ["system", "user", "assistant"])
    XCTAssertEqual(chat.history.map(\.content), ["system", "one", "answer"])
    XCTAssertEqual(chat.current.role.rawValue, "user")
    XCTAssertEqual(chat.current.content, "two")
  }

  func testChatMapperKeepsNoThinkOnCurrentUserOnly() throws {
    let request = ModelRequest(
      sessionID: "no-think",
      messages: [
        .init(role: .user, content: "one"),
        .init(role: .assistant, content: "answer"),
        .init(role: .user, content: "two"),
      ],
      tools: [])

    let chat = try MLXChatMapper.map(request: request, disablesThinking: true)

    XCTAssertEqual(chat.history.map(\.content), ["one", "answer"])
    XCTAssertEqual(chat.current.content, "two\n/no_think")
  }

  func testChatMapperPreservesMultipleToolCallsAndResults() throws {
    let calls = [
      LanguageModelCore.ToolCall(id: "one", name: "files.readText", arguments: .object(["path": "one.txt"])),
      LanguageModelCore.ToolCall(id: "two", name: "files.readText", arguments: .object(["path": "two.txt"]))
    ]
    let request = ModelRequest(sessionID: "tools", messages: [
      .init(role: .user, content: "Read both files."),
      .init(role: .assistant, content: "", toolCalls: calls),
      .init(role: .tool, content: "first", toolCallID: "one", toolName: "files.readText"),
      .init(role: .tool, content: "second", toolCallID: "two", toolName: "files.readText")
    ], tools: [])
    let mapped = try MLXChatMapper.map(request: request, disablesThinking: true)
    let raw = DefaultMessageGenerator().generate(messages: mapped.history + [mapped.current])
    XCTAssertEqual(raw.map { $0["role"] as? String }, ["user", "assistant", "tool", "tool"])
    let retained = try XCTUnwrap(raw[1]["tool_calls"] as? [[String: any Sendable]])
    XCTAssertEqual(retained.compactMap { $0["id"] as? String }, ["one", "two"])
    XCTAssertEqual(raw[2]["tool_call_id"] as? String, "one")
    XCTAssertEqual(raw[3]["tool_call_id"] as? String, "two")
    XCTAssertEqual(mapped.current.content, "second")
  }

  func testStructuredSchemaMergesIntoExistingSystemMessage() throws {
    let request = ModelRequest(sessionID: "schema-system", messages: [
      .init(role: .system, content: "Preserve my instructions."),
      .init(role: .user, content: "Return an object.")
    ], tools: [], outputFormat: .jsonObject(schema: .object(["type": "object"])))
    let mapped = try MLXChatMapper.map(request: request, disablesThinking: true)
    XCTAssertEqual(mapped.history.count, 1)
    XCTAssertEqual(mapped.history.first?.role.rawValue, "system")
    XCTAssertTrue(mapped.history[0].content.hasPrefix("Preserve my instructions."))
    XCTAssertTrue(mapped.history[0].content.contains("Schema:"))
  }

  func testModelClientRejectsUnsupportedCapabilitiesBeforeLoading() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "NativeAgentMLXTextClient-\(UUID().uuidString)")
    let store = try ModelArtifactStore(rootURL: root)
    let runtime = MLXTextRuntime(store: store)
    let model = try MLXModel(
      repositoryID: "mlx-community/Qwen3-1.7B-4bit",
      revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e")
    let client = MLXTextModelClient(runtime: runtime, model: model)
    let media = AgentMessage(
      id: "media-message",
      role: .user,
      contentParts: [.image(ModelBinaryContent(mimeType: "image/png", data: Data([1, 2, 3])))])
    let request = ModelRequest(sessionID: "media", messages: [media], tools: [])
    do {
      _ = try await client.generate(request: request)
      XCTFail("Media input must be rejected")
    } catch let failure as ModelGenerationFailure {
      XCTAssertEqual(failure.code, .invalidRequest)
    }
  }

  func testModelConfigurationUsesImmutableHubReferences() throws {
    XCTAssertEqual(MLXPins.mlxSwift, "0.32.3")
    XCTAssertEqual(MLXPins.mlxSwiftLM, "3.32.3")
    let model = try MLXModel(
      repositoryID: "mlx-community/example", revision: String(repeating: "a", count: 40))
    XCTAssertEqual(model.revision.count, 40)
    XCTAssertEqual(model.repositoryID, "mlx-community/example")
  }

  func testDecodingInvalidModelCannotBypassCanonicalValidation() throws {
    let data = Data(
      #"{"repositoryID":"mlx-community/example","revision":"main","extraEOSTokens":[],"disablesThinking":false,"sampling":{"temperature":0.7,"topP":0.8,"topK":20,"repetitionPenalty":1.05}}"#
        .utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(MLXModel.self, from: data)) { error in
      XCTAssertEqual(error as? MLXTextError, .invalidModel)
    }
  }

  func testResolvedManifestIdentityAndPublishedReadinessArePreserved() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let model = try MLXModel(
      repositoryID: "fixture/resolved", revision: String(repeating: "a", count: 40))
    let data = Data("resolved-model".utf8)
    let digest = ArtifactDigest(
      rawValue: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())!
    let manifest = try ArtifactManifest(
      artifactID: "mlx-text-0123456789abcdef",
      files: [
        try ArtifactEntry(
          path: "model.safetensors", byteCount: UInt64(data.count), sha256: digest)
      ])
    let staging = try await store.beginStaging(for: manifest)
    try data.write(to: staging.directoryURL.appending(path: "model.safetensors"))
    let published = try await store.publish(staging)
    published.close()

    let specification = try MLXModelSpecification(
      model: model, resolvedReference: model.hubReference, resolvedManifest: manifest)
    XCTAssertEqual(specification.manifest, manifest)

    let counters = Counters()
    let runtime = MLXTextRuntime(
      store: store,
      loader: fixtureLoader(counters: counters, output: "unused"))
    let readiness = try await runtime.readiness(specification: specification)
    XCTAssertEqual(readiness, .ready)

    let mismatchedReference = try MLXHubReference(
      repositoryID: "fixture/other", revision: model.revision)
    XCTAssertThrowsError(
      try MLXModelSpecification(
        model: model, resolvedReference: mismatchedReference, resolvedManifest: manifest)
    ) { error in
      XCTAssertEqual(error as? MLXTextError, .invalidModel)
    }
  }

  func testLoadHandleAtomicallyRejectsSuccessAfterQuarantine() async throws {
    let counters = Counters()
    let session = FixtureSession(counters: counters, output: "never-published")
    let handle = MLXLoadHandle()
    _ = handle.quarantine()

    XCTAssertTrue(handle.finish(.success(session)))
    do {
      _ = try handle.result()?.get()
      XCTFail("quarantined load must not publish success")
    } catch is CancellationError {}
  }

  func testPublishedSnapshotWarmGenerationLoadsOnce() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let specification = try tinySpecification(name: "one", value: "model-one")
    let counters = Counters()
    let runtime = MLXTextRuntime(
      store: store,
      loader: fixtureLoader(counters: counters, output: "hello"))

    let initialReadiness = try await runtime.readiness(specification: specification)
    XCTAssertEqual(initialReadiness, .missing)
    try await publishFixture(store: store, specification: specification)
    let preparedReadiness = try await runtime.readiness(specification: specification)
    XCTAssertEqual(preparedReadiness, .ready)

    let request = try textRequest("warm")
    let client = MLXTextModelClient(runtime: runtime, specification: specification)
    let first = try await client.generate(request: request)
    let second = try await client.generate(request: request)
    XCTAssertEqual(first.content, "hello")
    XCTAssertEqual(second.content, "hello")
    let loads = await counters.loads
    XCTAssertEqual(loads, 1)
    try await runtime.unload()
    let shutdowns = await counters.shutdowns
    let cacheClears = await counters.cacheClears
    XCTAssertEqual(shutdowns, 1)
    XCTAssertEqual(cacheClears, 1)
  }

  func testSwitchDrainsAndUnloadsBeforeLoadingNextModel() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let first = try tinySpecification(name: "first", value: "a")
    let second = try tinySpecification(name: "second", value: "b")
    let counters = Counters()
    let runtime = MLXTextRuntime(
      store: store,
      loader: fixtureLoader(counters: counters, output: "ok"))
    try await publishFixture(store: store, specification: first)
    try await publishFixture(store: store, specification: second)
    _ = try await collect(runtime: runtime, specification: first, request: textRequest("first"))
    _ = try await collect(runtime: runtime, specification: second, request: textRequest("second"))
    let loads = await counters.loads
    let shutdowns = await counters.shutdowns
    let cacheClears = await counters.cacheClears
    XCTAssertEqual(loads, 2)
    XCTAssertEqual(shutdowns, 1)
    XCTAssertEqual(cacheClears, 1)
    try await runtime.unload()
  }

  func testMissingSwitchPreservesWarmResident() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let first = try tinySpecification(name: "warm", value: "a")
    let missing = try tinySpecification(name: "missing-switch", value: "b")
    let counters = Counters()
    let runtime = MLXTextRuntime(
      store: store,
      loader: fixtureLoader(counters: counters, output: "ok"))
    try await publishFixture(store: store, specification: first)
    _ = try await collect(
      runtime: runtime, specification: first, request: textRequest("warm-first"))
    do {
      try await runtime.generate(
        specification: missing, request: textRequest("missing-second"), emit: { _ in })
      XCTFail("missing switch must fail")
    } catch MLXTextError.modelMissing {}
    _ = try await collect(
      runtime: runtime, specification: first, request: textRequest("warm-again"))
    let loads = await counters.loads
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(loads, 1)
    XCTAssertEqual(shutdowns, 0)
    try await runtime.unload()
  }

  func testProcessWideResidencyBlocksSecondRuntimeUntilFirstUnloads() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let first = try tinySpecification(name: "global-first", value: "a")
    let second = try tinySpecification(name: "second", value: "b")
    let counters = Counters()
    let firstRuntime = MLXTextRuntime(
      store: store, loader: fixtureLoader(counters: counters, output: "one"))
    let secondRuntime = MLXTextRuntime(
      store: store, loader: fixtureLoader(counters: counters, output: "two"))
    try await publishFixture(store: store, specification: first)
    try await publishFixture(store: store, specification: second)
    try await firstRuntime.generate(
      specification: first, request: textRequest("global-one"), emit: { _ in })
    do {
      try await secondRuntime.generate(
        specification: second, request: textRequest("global-two-busy"), emit: { _ in })
      XCTFail("second runtime must not load concurrently")
    } catch MLXTextError.busy {}
    var loads = await counters.loads
    XCTAssertEqual(loads, 1)
    try await firstRuntime.unload()
    try await secondRuntime.generate(
      specification: second, request: textRequest("global-two"), emit: { _ in })
    loads = await counters.loads
    XCTAssertEqual(loads, 2)
    try await secondRuntime.unload()
  }

  func testCancellationSurvivorIsQuarantinedUntilDrainCompletes() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let first = try tinySpecification(name: "stall", value: "a")
    let second = try tinySpecification(name: "second", value: "b")
    let counters = Counters()
    let gate = StallGate()
    let stalledRuntime = MLXTextRuntime(
      store: store,
      loader: .init(
        load: { _, _ in
          await counters.loaded()
          return StallingSession(gate: gate, counters: counters)
        },
        clearCache: { await counters.clearedCache() }))
    let otherRuntime = MLXTextRuntime(
      store: store, loader: fixtureLoader(counters: counters, output: "recovered"))
    try await publishFixture(store: store, specification: first)
    try await publishFixture(store: store, specification: second)
    let limits = try ModelGenerationLimits(maxDeadline: .seconds(1))
    let request = ModelRequest(
      sessionID: "stall", messages: [.init(role: .user, content: "stall")], tools: [],
      deadline: .milliseconds(50), limits: limits)
    let started = ContinuousClock.now
    do {
      _ = try await collect(
        runtime: stalledRuntime, specification: first, request: request)
      XCTFail("deadline must fail")
    } catch let failure as ModelGenerationFailure {
      XCTAssertEqual(failure.code, .deadlineExceeded)
    }
    XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    let drainingReadiness = try await stalledRuntime.readiness(specification: first)
    XCTAssertEqual(drainingReadiness, .busy)
    do {
      try await otherRuntime.generate(
        specification: second, request: textRequest("blocked-by-drain"), emit: { _ in })
      XCTFail("process residency must remain quarantined")
    } catch MLXTextError.busy {}

    await gate.release()
    var readiness: MLXReadiness = .busy
    for _ in 0..<100 {
      readiness = try await stalledRuntime.readiness(specification: first)
      if readiness == .ready { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(readiness, .ready)
    try await otherRuntime.generate(
      specification: second, request: textRequest("after-drain"), emit: { _ in })
    try await otherRuntime.unload()
  }

  func testMemoryWarningCancelsAndDrainsActiveGeneration() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let specification = try tinySpecification(name: "lifecycle", value: "model")
    let counters = Counters()
    let gate = StallGate()
    let runtime = MLXTextRuntime(
      store: store,
      loader: .init(
        load: { _, _ in
          await counters.loaded()
          return StallingSession(gate: gate, counters: counters)
        },
        clearCache: { await counters.clearedCache() }))
    try await publishFixture(store: store, specification: specification)
    let request = try textRequest("lifecycle")
    let generation = Task {
      try await runtime.generate(
        specification: specification, request: request, emit: { _ in })
    }
    try await Task.sleep(for: .milliseconds(30))
    let releaseGate = Task {
      try? await Task.sleep(for: .milliseconds(100))
      await gate.release()
    }
    try await runtime.handleMemoryWarning()
    await releaseGate.value
    do {
      try await generation.value
      XCTFail("memory warning must cancel generation")
    } catch is CancellationError {}
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 1)
    let readiness = try await runtime.readiness(specification: specification)
    XCTAssertEqual(readiness, .ready)

  }

  func testPinnedBackgroundAndThermalRecoveryPolicy() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let specification = try tinySpecification(name: "policy", value: "model")
    let counters = Counters()
    let runtime = MLXTextRuntime(
      store: store, loader: fixtureLoader(counters: counters, output: "ok"))
    try await publishFixture(store: store, specification: specification)
    let request = try textRequest("policy")
    try await runtime.generate(specification: specification, request: request, emit: { _ in })
    try await runtime.handleBackgroundEntry(pinned: true)
    try await runtime.generate(specification: specification, request: request, emit: { _ in })
    let loadsAfterPinned = await counters.loads
    XCTAssertEqual(loadsAfterPinned, 1)
    try await runtime.handleThermalState(.serious)
    let shutdownsAfterThermal = await counters.shutdowns
    XCTAssertEqual(shutdownsAfterThermal, 1)
    try await runtime.generate(specification: specification, request: request, emit: { _ in })
    let loadsAfterRecovery = await counters.loads
    XCTAssertEqual(loadsAfterRecovery, 2)
    try await runtime.handleThermalState(.nominal)
    try await runtime.handleBackgroundEntry()
    let shutdownsAfterBackground = await counters.shutdowns
    XCTAssertEqual(shutdownsAfterBackground, 2)
  }

  func testCancelledLoadRetainsProcessLeaseAfterRuntimeIsReleased() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let first = try tinySpecification(name: "load-stall", value: "a")
    let second = try tinySpecification(name: "second", value: "b")
    let counters = Counters()
    let gate = StallGate()
    var stalledRuntime: MLXTextRuntime? = MLXTextRuntime(
      store: store,
      loader: .init(
        load: { _, _ in
          await gate.wait()
          await counters.loaded()
          return FixtureSession(counters: counters, output: "late")
        },
        clearCache: { await counters.clearedCache() }))
    let otherRuntime = MLXTextRuntime(
      store: store, loader: fixtureLoader(counters: counters, output: "other"))
    try await publishFixture(store: store, specification: first)
    try await publishFixture(store: store, specification: second)
    var stalledClient: MLXTextModelClient? = MLXTextModelClient(
      runtime: stalledRuntime!, specification: first)
    let limits = try ModelGenerationLimits(maxDeadline: .seconds(1))
    let request = ModelRequest(
      sessionID: "load-stall", messages: [.init(role: .user, content: "stall")], tools: [],
      deadline: .milliseconds(50), limits: limits)
    do {
      _ = try await stalledClient!.generate(request: request)
      XCTFail("stalled load must hit the deadline")
    } catch let failure as ModelGenerationFailure {
      XCTAssertEqual(failure.code, .deadlineExceeded)
    }
    stalledClient = nil
    stalledRuntime = nil

    do {
      try await otherRuntime.generate(
        specification: second, request: textRequest("load-owner-retained"), emit: { _ in })
      XCTFail("released runtime must not release a surviving native load")
    } catch MLXTextError.busy {}

    await gate.release()
    var generated = false
    for attempt in 0..<100 where !generated {
      do {
        try await otherRuntime.generate(
          specification: second,
          request: textRequest("load-recovered-\(attempt)"), emit: { _ in })
        generated = true
      } catch MLXTextError.busy {
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    XCTAssertTrue(generated)
    let shutdowns = await counters.shutdowns
    let cacheClears = await counters.cacheClears
    XCTAssertGreaterThanOrEqual(shutdowns, 1)
    XCTAssertGreaterThanOrEqual(cacheClears, 1)
    try await otherRuntime.unload()
  }

  func testCancelledGenerationCleansNativeStateAfterRuntimeIsReleased() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let first = try tinySpecification(name: "generation-drop", value: "a")
    let second = try tinySpecification(name: "second", value: "b")
    let counters = Counters()
    let gate = StallGate()
    var stalledRuntime: MLXTextRuntime? = MLXTextRuntime(
      store: store,
      loader: .init(
        load: { _, _ in
          await counters.loaded()
          return StallingSession(gate: gate, counters: counters)
        },
        clearCache: { await counters.clearedCache() }))
    let otherRuntime = MLXTextRuntime(
      store: store, loader: fixtureLoader(counters: counters, output: "other"))
    try await publishFixture(store: store, specification: first)
    try await publishFixture(store: store, specification: second)
    var stalledClient: MLXTextModelClient? = MLXTextModelClient(
      runtime: stalledRuntime!, specification: first)
    let limits = try ModelGenerationLimits(maxDeadline: .seconds(1))
    let request = ModelRequest(
      sessionID: "generation-drop", messages: [.init(role: .user, content: "stall")],
      tools: [], deadline: .milliseconds(50), limits: limits)
    do {
      _ = try await stalledClient!.generate(request: request)
      XCTFail("stalled generation must hit the deadline")
    } catch let failure as ModelGenerationFailure {
      XCTAssertEqual(failure.code, .deadlineExceeded)
    }
    stalledClient = nil
    stalledRuntime = nil
    do {
      try await otherRuntime.generate(
        specification: second, request: textRequest("generation-owner-retained"), emit: { _ in })
      XCTFail("surviving generation must retain process ownership")
    } catch MLXTextError.busy {}

    await gate.release()
    var generated = false
    for attempt in 0..<100 where !generated {
      do {
        try await otherRuntime.generate(
          specification: second,
          request: textRequest("generation-recovered-\(attempt)"), emit: { _ in })
        generated = true
      } catch MLXTextError.busy {
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    XCTAssertTrue(generated)
    let events = await counters.eventLog()
    let shutdownIndex = try XCTUnwrap(events.firstIndex(of: "shutdown"))
    let cacheIndex = try XCTUnwrap(events.firstIndex(of: "cache"))
    let loadIndices = events.indices.filter { events[$0] == "load" }
    XCTAssertGreaterThanOrEqual(loadIndices.count, 2)
    XCTAssertLessThan(shutdownIndex, loadIndices.last!)
    XCTAssertLessThan(cacheIndex, loadIndices.last!)
    try await otherRuntime.unload()
  }

  func testMissingModelNeverInvokesLoaderOrNetworkDuringGeneration() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let specification = try tinySpecification(name: "missing", value: "none")
    let counters = Counters()
    let runtime = MLXTextRuntime(
      store: store,
      loader: fixtureLoader(counters: counters, output: "unexpected"))
    do {
      _ = try await collect(
        runtime: runtime, specification: specification, request: textRequest("missing"))
      XCTFail("missing model must fail")
    } catch let failure as ModelGenerationFailure {
      XCTAssertEqual(failure.code, .sourceUnavailable)
    }
    let loads = await counters.loads
    XCTAssertEqual(loads, 0)
  }

  func testFailedArtifactPublicationPreservesExistingSnapshot() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let good = try tinySpecification(name: "good", value: "good")
    let bad = try tinySpecification(name: "bad", value: "expected")
    let counters = Counters()
    let runtime = MLXTextRuntime(
      store: store,
      loader: fixtureLoader(counters: counters, output: "ok"))
    try await publishFixture(store: store, specification: good)
    do {
      try await publishFixture(
        store: store, specification: bad, overrideData: Data("tampered".utf8))
      XCTFail("digest mismatch must fail")
    } catch {}
    let goodReadiness = try await runtime.readiness(specification: good)
    let badReadiness = try await runtime.readiness(specification: bad)
    XCTAssertEqual(goodReadiness, .ready)
    XCTAssertEqual(badReadiness, .missing)
  }

  func testCorruptedPinnedSnapshotIsNeverReportedReady() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let specification = try tinySpecification(name: "corrupt", value: "original")
    let runtime = MLXTextRuntime(store: store)

    try await publishFixture(store: store, specification: specification)
    let lease = try await store.open(specification.manifest)
    let modelURL = lease.directoryURL.appending(path: "model.safetensors")
    lease.close()
    try Data("tampered".utf8).write(to: modelURL)

    do {
      _ = try await runtime.readiness(specification: specification)
      XCTFail("corrupted pinned bytes must never be reported ready")
    } catch let error as ArtifactStoreError {
      XCTAssertEqual(error, .digestMismatch)
    }
  }

  func testRemovingResidentModelUnloadsBeforeDeletingSnapshot() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let counters = Counters()
    let fixture = try tinySpecification(name: "remove", value: "file")
    let fixtureRuntime = MLXTextRuntime(
      store: store,
      loader: fixtureLoader(counters: counters, output: "ok"))

    try await publishFixture(store: store, specification: fixture)
    _ = try await collect(
      runtime: fixtureRuntime, specification: fixture, request: textRequest("remove"))
    try await fixtureRuntime.remove(specification: fixture)
    let readiness = try await fixtureRuntime.readiness(specification: fixture)
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(readiness, .missing)
    XCTAssertEqual(shutdowns, 1)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "native-agent-mlx-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func tinySpecification(name: String, value: String) throws -> MLXModelSpecification {
    let data = Data(value.utf8)
    let digest = ArtifactDigest(
      rawValue: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())!
    let specification = try MLXModelSpecification(
      model: try MLXModel(
        repositoryID: "fixture/\(name)",
        revision: String(repeating: name == "second" ? "b" : "a", count: 40)),
      repositoryID: "fixture/\(name)",
      revision: String(repeating: name == "second" ? "b" : "a", count: 40),
      files: [
        try ArtifactEntry(
          path: "model.safetensors", byteCount: UInt64(data.count), sha256: digest)
      ],
      extraEOSTokens: [],
      disablesThinking: false,
      sampling: .init(temperature: 0, topP: 1, topK: 0, repetitionPenalty: 1))
    fixturePayloads[specification.manifest.artifactID] = data
    return specification
  }

  private func publishFixture(
    store: ModelArtifactStore,
    specification: MLXModelSpecification,
    overrideData: Data? = nil
  ) async throws {
    do {
      let lease = try await store.open(specification.manifest)
      lease.close()
      return
    } catch {}
    guard let data = overrideData ?? fixturePayloads[specification.manifest.artifactID] else {
      XCTFail("Missing test fixture payload for \(specification.manifest.artifactID)")
      return
    }
    let staging = try await store.beginStaging(for: specification.manifest)
    do {
      try data.write(to: staging.directoryURL.appending(path: "model.safetensors"))
      let lease = try await store.publish(staging)
      lease.close()
    } catch {
      staging.abandon()
      throw error
    }
  }

  private func textRequest(_ id: String) throws -> ModelRequest {
    ModelRequest(
      sessionID: id,
      messages: [.init(role: .user, content: "hello")],
      tools: [])
  }

  private func collect(
    runtime: MLXTextRuntime,
    specification: MLXModelSpecification,
    request: ModelRequest
  ) async throws -> ModelTurn {
    try await MLXTextModelClient(runtime: runtime, specification: specification)
      .generate(request: request)
  }

  func testSpecificationArchiveSurvivesRuntimeRestartWithoutNetworkPreparation() async throws {
    // Restart scenario: a fresh runtime instance restores the resolved
    // specification from the sidecar archive and reports already-published
    // bytes ready without invoking the Hub preparation effect.
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root.appending(path: "store"), minimumFreeBytes: 0)
    let persistenceURL = root.appending(path: "resolved-specs.json")

    let model = try MLXModel(
      repositoryID: "fixture/persist", revision: String(repeating: "b", count: 40))
    let data = Data("persist-model".utf8)
    let digest = ArtifactDigest(
      rawValue: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())!
    let manifest = try ArtifactManifest(
      artifactID: "mlx-text-persist",
      files: [
        try ArtifactEntry(
          path: "model.safetensors", byteCount: UInt64(data.count), sha256: digest)
      ])

    let staging = try await store.beginStaging(for: manifest)
    try data.write(to: staging.directoryURL.appending(path: "model.safetensors"))
    let published = try await store.publish(staging)
    published.close()

    let specification = try MLXModelSpecification(
      model: model, resolvedReference: model.hubReference, resolvedManifest: manifest)

    // First session writes the archive (what resolve() does on success).
    let entries = [
      MLXSpecificationArchive.Entry(model: model, specification: specification)
    ]
    try MLXSpecificationArchive.save(entries, to: persistenceURL)

    // Second session: brand-new runtime instance over the same store+archive.
    let counters = Counters()
    let restarted = MLXTextRuntime(
      store: store,
      loader: fixtureLoader(counters: counters, output: "unused"),
      specificationsPersistenceURL: persistenceURL)

    let readiness: MLXReadiness = try await restarted.readiness(for: model)
    XCTAssertEqual(readiness, .ready)
    let changedSampling = try MLXModel(repositoryID: model.repositoryID, revision: model.revision,
      sampling: .init(temperature: 0, topP: 1, topK: 0, repetitionPenalty: 1))
    let prepared = try await restarted.prepare(changedSampling)
    XCTAssertEqual(prepared.model, changedSampling)
    let registeredModels = try await restarted.registeredModels()
    XCTAssertEqual(registeredModels, [model])
    let connector = try MLXHubModelProviderConnector(runtime: restarted)
    let catalog = try await connector.models()
    XCTAssertEqual(catalog.map(\.id), ["fixture/persist@\(model.revision)"])
    let connectorAvailability = try await connector.availability()
    XCTAssertEqual(connectorAvailability, .available)
    let restored = try MLXSpecificationArchive.load(from: persistenceURL)
    XCTAssertEqual(restored.count, 2)
    XCTAssertTrue(restored.allSatisfy { $0.specification.manifest == manifest })
    let validBytes = try Data(contentsOf: persistenceURL)
    XCTAssertThrowsError(try MLXSpecificationArchive.save(
      Array(repeating: entries[0], count: MLXSpecificationArchive.maximumEntries + 1),
      to: persistenceURL)) { error in
        XCTAssertEqual(error as? MLXTextPersistenceError, .oversized)
      }
    XCTAssertEqual(try Data(contentsOf: persistenceURL), validBytes)

  }

  private func fixtureLoader(counters: Counters, output: String) -> MLXSessionLoader {
    .init(
      load: { _, _ in
        await counters.loaded()
        return FixtureSession(counters: counters, output: output)
      },
      clearCache: { await counters.clearedCache() })
  }
}

private actor FixtureSession: MLXLoadedSession {
  let counters: Counters
  let output: String
  init(counters: Counters, output: String) {
    self.counters = counters
    self.output = output
  }
  func generate(
    request: ModelRequest,
    emit: @escaping @Sendable (ModelEvent) -> Void
  ) async throws {
    try Task.checkCancellation()
    let usage = ModelUsage(inputTokens: 1, outputTokens: 1, totalTokens: 2)
    emit(.textDelta(output))
    emit(.usage(usage))
    emit(.completed(ModelTurn(content: output, usage: usage, stopReason: .stop)))
  }
  func shutdown() async { await counters.shutDown() }
}

private actor StallGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private actor StallingSession: MLXLoadedSession {
  let gate: StallGate
  let counters: Counters
  init(gate: StallGate, counters: Counters) {
    self.gate = gate
    self.counters = counters
  }
  func generate(
    request: ModelRequest,
    emit: @escaping @Sendable (ModelEvent) -> Void
  ) async throws {
    await gate.wait()
    let usage = ModelUsage(inputTokens: 1, outputTokens: 0, totalTokens: 1)
    emit(.usage(usage))
    emit(.completed(ModelTurn(content: "", usage: usage, stopReason: .stop)))
  }
  func shutdown() async { await counters.shutDown() }
}

private actor Counters {
  private(set) var loads = 0
  private(set) var shutdowns = 0
  private(set) var cacheClears = 0
  private var events: [String] = []
  func loaded() {
    loads += 1
    events.append("load")
  }
  func shutDown() {
    shutdowns += 1
    events.append("shutdown")
  }
  func clearedCache() {
    cacheClears += 1
    events.append("cache")
  }
  func eventLog() -> [String] { events }
}
