import ModelArtifactStore
import CryptoKit
import Foundation
import LanguageModelCore
import LanguageModelRuntime
import XCTest

@preconcurrency import LeapSDK
@testable import LEAPProvider
private typealias LeapError = LEAPProvider.LeapError

final class LeapTests: XCTestCase {
  func testDownloadValidationRequiresHTTP200RegularFileAndExactSize() {
    XCTAssertNoThrow(
      try LeapDownloadValidation.validate(
        statusCode: 200, isRegularFile: true, fileSize: 4, expectedByteCount: 4))

    XCTAssertThrowsError(
      try LeapDownloadValidation.validate(
        statusCode: 206, isRegularFile: true, fileSize: 4, expectedByteCount: 4)
    ) { error in
      XCTAssertEqual(error as? LeapError, .nativeFailure)
    }
    XCTAssertThrowsError(
      try LeapDownloadValidation.validate(
        statusCode: 200, isRegularFile: false, fileSize: 4, expectedByteCount: 4)
    ) { error in
      XCTAssertEqual(error as? LeapError, .invalidArtifact)
    }
    XCTAssertThrowsError(
      try LeapDownloadValidation.validate(
        statusCode: 200, isRegularFile: true, fileSize: 3, expectedByteCount: 4)
    ) { error in
      XCTAssertEqual(error as? LeapError, .invalidArtifact)
    }
  }

  func testDownloadFileCommitMovesOnlyAValidatedExactRegularFile() throws {
    let root = try temporaryDirectory()
    let temporary = root.appending(path: "temporary.bin")
    let destination = root.appending(path: "staging/model.bin")
    try Data("file".utf8).write(to: temporary)

    try LeapDownloadFileCommit.moveValidatedResponse(
      from: temporary,
      statusCode: 200,
      expectedByteCount: 4,
      to: destination)
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    XCTAssertEqual(try Data(contentsOf: destination), Data("file".utf8))

    let replacement = root.appending(path: "replacement.bin")
    try Data("file".utf8).write(to: replacement)
    XCTAssertThrowsError(
      try LeapDownloadFileCommit.moveValidatedResponse(
        from: replacement,
        statusCode: 200,
        expectedByteCount: 4,
        to: destination),
      "a completed destination must not be overwritten")
    XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
  }

  func testDownloadTerminalGateResolvesCancellationAndDuplicateCompletionExactlyOnce() {
    let gate = LeapDownloadTerminalGate()
    XCTAssertTrue(gate.beginFinishing())
    XCTAssertFalse(gate.beginFinishing())
    XCTAssertFalse(gate.requestCancellation(), "finishing owns the continuation")
    XCTAssertEqual(gate.resolve(), .cancelled)
    XCTAssertNil(gate.resolve(), "a duplicate delegate terminal callback is ignored")
    XCTAssertFalse(gate.requestCancellation())

    let immediate = LeapDownloadTerminalGate()
    XCTAssertTrue(immediate.requestCancellation())
    XCTAssertNil(immediate.resolve())
  }

  func testDownloadProgressAggregationIsBoundedAndMonotonicAcrossSequentialFiles() {
    let values = [
      LeapDownloadProgressAggregation.aggregate(
        completedBytes: 0, fileBytesWritten: 0, fileByteCount: 2, totalBytes: 5),
      LeapDownloadProgressAggregation.aggregate(
        completedBytes: 0, fileBytesWritten: 1, fileByteCount: 2, totalBytes: 5),
      LeapDownloadProgressAggregation.aggregate(
        completedBytes: 2, fileBytesWritten: 0, fileByteCount: 3, totalBytes: 5),
      LeapDownloadProgressAggregation.aggregate(
        completedBytes: 2, fileBytesWritten: 3, fileByteCount: 3, totalBytes: 5),
    ].compactMap { $0 }
    XCTAssertEqual(values, [0, 1, 2, 5])
    XCTAssertEqual(
      LeapDownloadProgressAggregation.aggregate(
        completedBytes: 2, fileBytesWritten: 4, fileByteCount: 3, totalBytes: 5),
      nil)
    XCTAssertEqual(
      LeapDownloadProgressAggregation.aggregate(
        completedBytes: UInt64.max, fileBytesWritten: 1, fileByteCount: 1, totalBytes: UInt64.max),
      nil)
  }

  func testModelClientRejectsMediaAndToolsBeforeRuntimeDispatch() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: Counters()),
      loader: .init(load: { _ in FixtureSession(counters: Counters()) }))
    let client = LeapModelClient(runtime: runtime, model: .qad)
    let image = AgentMessage(
      role: .user,
      contentParts: [.image(ModelBinaryContent(mimeType: "image/png", data: Data([1])))])
    let mediaRequest = ModelRequest(sessionID: "s", messages: [image], tools: [])
    do {
      _ = try await client.generate(request: mediaRequest)
      XCTFail("media must be rejected before native dispatch")
    } catch let failure as ModelGenerationFailure {
      XCTAssertEqual(failure.code, .policyViolation)
    }
    let text = AgentMessage(role: .user, content: "hello")
    let toolRequest = ModelRequest(
      sessionID: "s", messages: [text],
      tools: [ModelTool(name: "lookup", description: "lookup", inputSchema: .object([:]))])
    do {
      _ = try await client.generate(request: toolRequest)
      XCTFail("tools must be rejected before native dispatch")
    } catch let failure as ModelGenerationFailure {
      XCTAssertEqual(failure.code, .policyViolation)
    }
  }

  func testPinsAreImmutableAndComplete() throws {
    let model = LeapVoiceModel.pinned
    XCTAssertEqual(model.revision.count, 40)
    XCTAssertEqual(model.manifest.totalBytes, 1_063_770_528)
    XCTAssertEqual(model.manifest.files.count, 3)
  }

  func testPinnedQADTextModelIsExactAndValidated() throws {
    let model = LeapTextModel.qad
    XCTAssertEqual(model.repositoryID, "LiquidAI/LFM2.5-2.6B-GGUF")
    XCTAssertEqual(model.revision, "84022ce711b28455e8c4fc364ce68c00cf995875")
    XCTAssertEqual(model.modelPath, "LFM2.5-2.6B-QAD-Q4_0.gguf")
    XCTAssertEqual(model.manifest.files.count, 1)
    XCTAssertEqual(model.manifest.files[0].byteCount, 1_593_894_944)
    XCTAssertEqual(
      model.manifest.files[0].sha256.rawValue,
      "a247afd6414918eac8e520a9e6137dc271235461ecbe1180462221d5b8d40b03")
    XCTAssertEqual(
      model.manifestDigest.rawValue,
      "5c68f7dc81e7a85e225dc9cf1840b7a419b104ef1c63229ac5c1c612f35eb549")
    XCTAssertEqual(model.identity.modelPath, model.modelPath)
    XCTAssertEqual(model.identity.manifestDigest, model.manifestDigest)
    XCTAssertEqual(model.manifest.totalBytes, 1_593_894_944)
  }

  func testPinnedQAD1_2BTextModelIsExactAndValidated() throws {
    let model = LeapTextModel.default
    XCTAssertEqual(model, .qad1_2B)
    XCTAssertEqual(model.repositoryID, "LiquidAI/LFM2.5-1.2B-Instruct-GGUF")
    XCTAssertEqual(model.revision, "6767265158422fb8a19c62ceb45f16f05363615b")
    XCTAssertEqual(model.modelPath, "LFM2.5-1.2B-Instruct-QAD-Q4_0.gguf")
    XCTAssertEqual(
      model.manifest.artifactID,
      "leap-lfm2.5-1.2b-instruct-qad-q4_0-6767265158422fb8a19c62ceb45f16f05363615b")
    XCTAssertEqual(model.manifest.files.count, 1)
    XCTAssertEqual(model.manifest.files[0].byteCount, 695_755_488)
    XCTAssertEqual(
      model.manifest.files[0].sha256.rawValue,
      "bb741ebb106d543e9de114b843a3d3d73d51c74b5801e69da2abde821a0cb3e1")
    XCTAssertEqual(
      model.manifestDigest.rawValue,
      "f7bed5536ede3b9eb43637834b5ab482796640800cc8ad183cdbcc7df03f0f58")
    XCTAssertEqual(model.identity.modelPath, model.modelPath)
    XCTAssertEqual(model.identity.manifestDigest, model.manifestDigest)
    XCTAssertEqual(model.manifest.totalBytes, 695_755_488)
    XCTAssertNotEqual(model.identity, LeapTextModel.qad.identity)
  }

  func testDefaultTextPrepareRoutesToLFM1_2BWithoutNativeInference() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let downloader = DefaultSelectionDownloader()
    let runtime = LeapRuntime(
      store: store, downloader: downloader,
      loader: .init(load: { _ in throw LeapError.nativeFailure }))
    do {
      _ = try await runtime.prepare()
      XCTFail("The test downloader stops before downloading any model")
    } catch LeapError.nativeFailure {}
    let observed = await downloader.observed
    XCTAssertEqual(observed?.repositoryID, LeapTextModel.qad1_2B.repositoryID)
    XCTAssertEqual(observed?.revision, LeapTextModel.qad1_2B.revision)
    XCTAssertEqual(observed?.manifest, LeapTextModel.qad1_2B.manifest)
  }

  func testManagedTextPrepareIsVerifiedIdempotentAndIdentityBound() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let openCounter = ArtifactOpenCounter()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      textLoader: .init(load: { _ in TextFixtureSession(counters: counters) }),
      artifactOpenObserver: { openCounter.increment() })
    let model = try tinyTextModel()
    let samePathDifferentIdentity = try tinyTextModel(
      artifactID: "text-fixture-other", revision: String(repeating: "c", count: 40))

    let missingReadiness = try await runtime.readiness(for: model)
    XCTAssertEqual(missingReadiness, LeapReadiness.missing)
    openCounter.reset()
    try await runtime.prepare(model)
    XCTAssertEqual(
      openCounter.value, 1, "cold prepare probes missing once; publish transfers its verified lease"
    )
    let otherReadiness = try await runtime.readiness(for: samePathDifferentIdentity)
    XCTAssertEqual(otherReadiness, LeapReadiness.missing)
    openCounter.reset()
    try await runtime.prepare(model)
    let preparedReadiness = try await runtime.readiness(for: model)
    try await runtime.load(model)
    let loadedReadiness = try await runtime.readiness(for: model)
    try await runtime.unload()
    let cachedReadiness = try await runtime.readiness(for: model)
    let downloads = await counters.downloads
    XCTAssertEqual(preparedReadiness, LeapReadiness.ready)
    XCTAssertEqual(loadedReadiness, LeapReadiness.ready)
    XCTAssertEqual(cachedReadiness, LeapReadiness.ready)
    XCTAssertEqual(
      openCounter.value, 0, "warm prepare/readiness/load/unload must reuse the verified lease")
    try await runtime.remove(model)
    let removedReadiness = try await runtime.readiness(for: model)
    XCTAssertEqual(removedReadiness, LeapReadiness.missing)
    XCTAssertEqual(openCounter.value, 1, "removal invalidates the cached lease")
    XCTAssertEqual(downloads, 1)
  }

  func testPrepareCancellationAfterReapDoesNotPublish() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let reapGate = Gate()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      beforeReapDrain: { await reapGate.wait() })
    let model = try tinyTextModel()

    let prepare = Task { try await runtime.prepare(model) }
    let reapEntered = await waitForGateEntered(reapGate)
    XCTAssertTrue(reapEntered)
    prepare.cancel()
    await reapGate.release()
    do {
      _ = try await prepare.value
      XCTFail("cancelled prepare must stop after reap")
    } catch is CancellationError {}

    let downloads = await counters.downloads
    XCTAssertEqual(downloads, 0)
    let readiness = try await runtime.readiness(for: model)
    XCTAssertEqual(readiness, .missing)
  }

  func testImportCancellationAfterVerificationDoesNotCacheLease() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let model = try tinyTextModel()
    try await publishFixture(store, for: model)
    let openGate = Gate()
    let openCounter = ArtifactOpenCounter()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: Counters()),
      loader: .init(load: { _ in FixtureSession(counters: Counters()) }),
      artifactOpenObserver: { openCounter.increment() },
      beforeArtifactOpen: { await openGate.wait() })
    let source = try temporaryDirectory()
    try Data("fixture".utf8).write(to: source.appending(path: model.modelPath))

    let importing = Task { try await runtime.importModel(model, from: source) }
    let openEntered = await waitForGateEntered(openGate)
    XCTAssertTrue(openEntered)
    importing.cancel()
    await openGate.release()
    do {
      _ = try await importing.value
      XCTFail("cancelled import must not cache a verified lease")
    } catch is CancellationError {}
    XCTAssertEqual(openCounter.value, 1)

    let readiness = try await runtime.readiness(for: model)
    XCTAssertEqual(readiness, .ready)
    XCTAssertEqual(openCounter.value, 2, "readiness must re-open after cancelled import")
    try await runtime.remove(model)
  }

  func testReadinessCancellationAfterVerificationDoesNotCacheLease() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let model = try tinyTextModel()
    try await publishFixture(store, for: model)
    let openGate = Gate()
    let openCounter = ArtifactOpenCounter()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: Counters()),
      loader: .init(load: { _ in FixtureSession(counters: Counters()) }),
      artifactOpenObserver: { openCounter.increment() },
      beforeArtifactOpen: { await openGate.wait() })

    let readiness = Task { try await runtime.readiness(for: model) }
    let openEntered = await waitForGateEntered(openGate)
    XCTAssertTrue(openEntered)
    readiness.cancel()
    await openGate.release()
    do {
      _ = try await readiness.value
      XCTFail("cancelled readiness must not cache a verified lease")
    } catch is CancellationError {}
    XCTAssertEqual(openCounter.value, 1)

    let recoveredReadiness = try await runtime.readiness(for: model)
    XCTAssertEqual(recoveredReadiness, .ready)
    XCTAssertEqual(openCounter.value, 2, "a cancelled readiness verification must not be reused")
    try await runtime.remove(model)
  }

  func testManagedTextImportAndRemoveUseManifestIdentity() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: Counters()),
      loader: .init(load: { _ in FixtureSession(counters: Counters()) }))
    let model = try tinyTextModel()
    let source = try temporaryDirectory()
    try Data("fixture".utf8).write(to: source.appending(path: model.modelPath))

    try await runtime.importModel(model, from: source)
    let importedReadiness = try await runtime.readiness(for: model)
    XCTAssertEqual(importedReadiness, LeapReadiness.ready)
    try await runtime.remove(model)
    let removedReadiness = try await runtime.readiness(for: model)
    XCTAssertEqual(removedReadiness, LeapReadiness.missing)
  }

  func testManagedTextGenerationKeepsResidentUntilExplicitUnload() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      textLoader: .init(load: { _ in
        await counters.loaded()
        return TextFixtureSession(counters: counters)
      }))
    let model = try tinyTextModel()
    let prepared = try await runtime.prepare(model)
    XCTAssertEqual(prepared.identity, model.identity)
    try await runtime.load(prepared)
    let turn = try await runtime.modelClient(for: model).generate(
      request: ModelRequest(
        sessionID: "text", messages: [AgentMessage(role: .user, content: "client")], tools: []))
    let first = try await runtime.generateTextStream(
      for: model, history: [.init(role: .system, content: "system")], userMessage: "first", emit: { _ in })
    let second = try await runtime.generateTextStream(
      for: model, history: [.init(role: .system, content: "system")], userMessage: "second", emit: { _ in })
    XCTAssertEqual(first, "fixture response")
    XCTAssertEqual(second, "fixture response")
    XCTAssertEqual(turn.content, "fixture response")
    let loads = await counters.loads
    let shutdownsBeforeUnload = await counters.shutdowns
    let residentReadiness = try await runtime.readiness(for: model)
    XCTAssertEqual(loads, 1)
    XCTAssertEqual(shutdownsBeforeUnload, 0)
    XCTAssertEqual(residentReadiness, LeapReadiness.ready)
    try await runtime.unload()
    let shutdowns = await counters.shutdowns
    let preparedReadiness = try await runtime.readiness(for: model)
    XCTAssertEqual(shutdowns, 1)
    XCTAssertEqual(preparedReadiness, LeapReadiness.ready)
  }

  func testTextModelClientPreservesCanonicalMultiTurnHistory() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let recorder = TextHistoryRecorder()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: Counters()),
      loader: .init(load: { _ in FixtureSession(counters: Counters()) }),
      textLoader: .init(load: { _ in RecordingTextSession(recorder: recorder) }))
    let model = try tinyTextModel()
    let prepared = try await runtime.prepare(model)
    try await runtime.load(prepared)

    let turn = try await runtime.modelClient(for: model).generate(
      request: ModelRequest(
        sessionID: "multi-turn",
        messages: [
          AgentMessage(role: .system, content: "system"),
          AgentMessage(role: .user, content: "one"),
          AgentMessage(role: .assistant, content: "first answer"),
          AgentMessage(role: .user, content: "two"),
        ],
        tools: []))

    XCTAssertEqual(turn.content, "fixture response")
    let invocation = await recorder.value()
    XCTAssertEqual(invocation?.history, [
      LeapTextMessage(role: .system, content: "system"),
      LeapTextMessage(role: .user, content: "one"),
      LeapTextMessage(role: .assistant, content: "first answer"),
    ])
    XCTAssertEqual(invocation?.userMessage, "two")
  }

  func testUnsupportedStringBoundsFailBeforeNativeGeneration() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let client = LeapModelClient(runtime: LeapRuntime(store: store), model: .qad)
    let schema = JSONValue.object(["type": .string("object"), "properties": .object([
      "text": .object(["type": .string("string"), "maxLength": .integer(16_384)])
    ])])
    do {
      _ = try await client.generate(request: ModelRequest(sessionID: "invalid-grammar",
        messages: [AgentMessage(role: .user, content: "text")], tools: [], outputFormat: .jsonObject(schema: schema)))
      XCTFail("An unsupported grammar must never reach the unloaded native model")
    } catch let error as ModelGenerationFailure {
      XCTAssertEqual(error.code, .invalidRequest)
      XCTAssertTrue(error.message.contains("maxLength"))
    }
  }

  func testSchemaBoundsWalkDefinitionsButPreserveLiteralData() throws {
    let literal = JSONValue.object(["maxLength": .integer(16_384)])
    XCTAssertNoThrow(try LeapTextGenerationPolicy.validate(.jsonObject(schema: .object([
      "type": .string("object"), "const": literal, "default": literal, "examples": .array([literal]),
      "properties": .object(["maxLength": .object(["type": .string("integer"), "const": .integer(16_384)])])
    ]))))
    XCTAssertThrowsError(try LeapTextGenerationPolicy.validate(.jsonObject(schema: .object([
      "$defs": .object(["long": .object(["type": .string("string"), "minLength": .integer(2_000)])])
    ]))))
  }

  func testCurrentNativeJSONEnvelopeIsDecodedWithoutRepair() throws {
    XCTAssertEqual(try LeapJSONOutput.decode("```json\n{\"ok\":true}\n```", maximumBytes: 11), "{\"ok\":true}")
    XCTAssertEqual(try LeapJSONOutput.decode(" {} ", maximumBytes: 2), "{}")
    for invalid in ["```python\n{}\n```", "before\n```json\n{}\n```", "```json\n{}\n```\nafter", "```json\n{} {}\n```", "```json\n[]\n```", "```json\n{\n```"] {
      XCTAssertThrowsError(try LeapJSONOutput.decode(invalid, maximumBytes: 128))
    }
    XCTAssertThrowsError(try LeapJSONOutput.decode("```json\n{\"ok\":true}\n```", maximumBytes: 10))
  }

  func testCurrentNativeSDKVersion() {
    XCTAssertEqual(LeapSDKVersion.shared.version, "0.11.0-SNAPSHOT")
  }

  func testNativeGenerationOptionsPreserveSchemaWhenSettingSampling() throws {
    let schema = JSONValue.object(["type": .string("object")])
    let options = try LeapTextGenerationPolicy.options(for: .jsonObject(schema: schema))
    XCTAssertEqual((options.constraint as? GenerationConstraint.JsonSchema)?.schema, try schema.canonicalString())
    XCTAssertEqual(options.temperature?.floatValue, LeapTextGenerationPolicy.structuredOutputTemperature)
    XCTAssertEqual(options.maxTokens?.int32Value, LeapLimits.maxTextGenerationTokens)
    let textOptions = try LeapTextGenerationPolicy.options(for: .text)
    XCTAssertNil(textOptions.constraint)
    XCTAssertNil(textOptions.temperature)
  }

  func testStructuredOutputReachesNativeSessionAndKeepsTextMode() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let recorder = TextHistoryRecorder()
    let provider = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: Counters()),
      loader: .init(load: { _ in FixtureSession(counters: Counters()) }),
      textLoader: .init(load: { _ in RecordingTextSession(recorder: recorder) }))
    let model = try tinyTextModel()
    let runtime = try await provider.makeTextRuntime(provider.prepare(model))
    XCTAssertTrue(runtime.modelDescriptor.capabilities.contains(.structuredOutput))
    let format = ModelOutputFormat.jsonObject(schema: .object([
      "type": .string("object"),
      "properties": .object(["question": .object(["type": .string("string")])]),
      "required": .array([.string("question")]),
    ]))
    let turn = try await runtime.generate(ModelRequest(
      sessionID: "structured", messages: [AgentMessage(role: .user, content: "question")],
      tools: [], outputFormat: format))
    let first = await recorder.value()
    XCTAssertEqual(first?.outputFormat, format)
    XCTAssertEqual(turn.content, #"{"question":"What happened?"}"#)
    _ = try await runtime.generate(ModelRequest(
      sessionID: "text", messages: [AgentMessage(role: .user, content: "plain")], tools: []))
    let second = await recorder.value()
    XCTAssertEqual(second?.outputFormat, .text)
    try await runtime.shutdown()
    try await provider.unload()
  }

  func testNativeEnvelopeNeverLeaksIntoStructuredEvents() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let provider = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: Counters()),
      loader: .init(load: { _ in FixtureSession(counters: Counters()) }),
      textLoader: .init(load: { _ in RecordingTextSession(recorder: TextHistoryRecorder(),
        jsonChunks: ["```js", "on\n{", "}", "\n``", "`"]) }))
    let model = try tinyTextModel()
    let runtime = try await provider.makeTextRuntime(provider.prepare(model))
    let run = try await runtime.start(ModelRequest(
      sessionID: "enveloped", messages: [.init(role: .user, content: "JSON")], tools: [],
      outputFormat: .jsonObject(schema: .object(["type": .string("object")])), maxOutputBytes: 2))
    var streamed = ""
    var completed: String?
    for try await event in run.events {
      if case .textDelta(let delta) = event { streamed += delta }
      if case .completed(let turn) = event { completed = turn.content }
    }
    XCTAssertEqual(streamed, "{}")
    XCTAssertEqual(completed, "{}")
    try await runtime.shutdown()
    try await provider.unload()
  }

  func testPreparedTextRuntimeIsThePublicInvocationSurface() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let provider = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      textLoader: .init(load: { _ in
        await counters.loaded()
        return TextFixtureSession(counters: counters)
      }))
    let model = try tinyTextModel()
    let prepared = try await provider.prepare(model)
    let runtime = try await provider.makeTextRuntime(prepared)
    let turn = try await runtime.generate(
      ModelRequest(
        sessionID: "prepared-runtime",
        messages: [AgentMessage(role: .user, content: "hello")],
        tools: []))
    XCTAssertEqual(turn.content, "fixture response")
    try await runtime.shutdown()
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 0)
    try await provider.unload()
    let residentShutdowns = await counters.shutdowns
    XCTAssertEqual(residentShutdowns, 1)
  }

  func testPreparedTextRuntimeRetainsDescriptorValidationFailureAfterNativeLoad() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let provider = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      textLoader: .init(load: { _ in
        await counters.loaded()
        return TextFixtureSession(counters: counters)
      }))
    let prepared = try await provider.prepare(try tinyTextModel(displayName: "invalid\nname"))

    do {
      _ = try await provider.makeTextRuntime(prepared)
      XCTFail("An invalid descriptor must not publish a runtime")
    } catch let failure as ModelGenerationFailure {
      XCTAssertEqual(failure.code, .invalidRequest)
    }

    let loads = await counters.loads
    XCTAssertEqual(loads, 1, "Validation remains after the loaded resident boundary")
    try await provider.unload()
  }

  func testConcurrentSameModelLoadsShareOneNativeLoadAndCommitMatchingToken() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let gate = Gate()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      textLoader: .init(load: { url in
        await gate.wait()
        await counters.loaded()
        return TextFixtureSession(counters: counters)
      }))
    let model = try tinyTextModel()
    try await runtime.prepare(model)

    let first = Task { try await runtime.load(model) }
    let firstEntered = await waitForGateEntered(gate)
    XCTAssertTrue(firstEntered)
    let second = Task {
      try await runtime.load(model)
      return try await runtime.readiness(for: model)
    }
    await gate.release()
    try await first.value
    let joinedReadiness = try await second.value

    let loads = await counters.loads
    let readiness = try await runtime.readiness(for: model)
    XCTAssertEqual(loads, 1)
    XCTAssertEqual(joinedReadiness, .ready)
    XCTAssertEqual(readiness, .ready)
    let output = try await runtime.generateTextStream(
      for: model, history: [.init(role: .system, content: "system")], userMessage: "shared", emit: { _ in })
    XCTAssertEqual(output, "fixture response")
    try await runtime.unload()
  }

  func testManagedTextCancellationDrainsBeforeReuse() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let gate = Gate()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      watchdog: .init(total: .seconds(1), inactivity: .milliseconds(30)),
      textLoader: .init(load: { _ in
        if await counters.loadedAndWasFirst() {
          return TextStallingSession(gate: gate, counters: counters)
        }
        return TextFixtureSession(counters: counters)
      }))
    let model = try tinyTextModel()
    try await runtime.prepare(model)
    try await runtime.load(model)
    let generation = Task {
      try await runtime.generateTextStream(
        for: model, history: [.init(role: .system, content: "system")], userMessage: "wait", emit: { _ in })
    }
    let generationEntered = await waitForGateEntered(gate)
    XCTAssertTrue(generationEntered)
    generation.cancel()
    do {
      _ = try await generation.value
      XCTFail("cancelled text generation must return cancellation")
    } catch is CancellationError {}
    let drainingReadiness = try await runtime.readiness(for: model)
    XCTAssertEqual(drainingReadiness, LeapReadiness.busy)
    do {
      _ = try await runtime.generateTextStream(
        for: model, history: [.init(role: .system, content: "system")], userMessage: "reuse", emit: { _ in })
      XCTFail("a draining runner must reject reuse")
    } catch LeapError.busy {}
    await gate.release()
    for _ in 0..<100 {
      if try await runtime.readiness(for: model) == .ready { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await runtime.load(model)
    let recovered = try await runtime.generateTextStream(
      for: model, history: [.init(role: .system, content: "system")], userMessage: "recovered", emit: { _ in })
    XCTAssertEqual(recovered, "fixture response")
    try await runtime.unload()
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 2)
  }

  func testDifferentTextModelSwitchUnloadsOldRunnerBeforeOneNewLoad() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      textLoader: .init(load: { _ in
        await counters.loaded()
        return TextFixtureSession(counters: counters)
      }))
    let oldModel = try tinyTextModel()
    let newModel = try tinyTextModel(
      artifactID: "text-fixture-switch", revision: String(repeating: "d", count: 40))
    try await runtime.prepare(oldModel)
    try await runtime.prepare(newModel)
    try await runtime.load(oldModel)
    try await runtime.load(newModel)

    let loadsAfterSwitch = await counters.loads
    let shutdownsAfterSwitch = await counters.shutdowns
    XCTAssertEqual(loadsAfterSwitch, 2)
    XCTAssertEqual(shutdownsAfterSwitch, 1)
    let output = try await runtime.generateTextStream(
      for: newModel, history: [.init(role: .system, content: "system")], userMessage: "switched", emit: { _ in })
    XCTAssertEqual(output, "fixture response")
    try await runtime.unload()
    let shutdownsAfterUnload = await counters.shutdowns
    XCTAssertEqual(shutdownsAfterUnload, 2)
  }

  func testCancelledDifferentModelSwitchDoesNotStartNewLoaderOrLeakResidency() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let shutdownGate = Gate()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      textLoader: .init(load: { _ in
        if await counters.loadedAndWasFirst() {
          return BlockingShutdownTextSession(gate: shutdownGate, counters: counters)
        }
        return TextFixtureSession(counters: counters)
      }))
    let oldModel = try tinyTextModel()
    let newModel = try tinyTextModel(
      artifactID: "text-fixture-cancelled-switch", revision: String(repeating: "e", count: 40))
    try await runtime.prepare(oldModel)
    try await runtime.prepare(newModel)
    try await runtime.load(oldModel)

    let switchTask = Task { try await runtime.load(newModel) }
    let shutdownEntered = await waitForGateEntered(shutdownGate)
    XCTAssertTrue(shutdownEntered)
    switchTask.cancel()
    await shutdownGate.release()
    do {
      try await switchTask.value
      XCTFail("cancelled switch must not succeed")
    } catch is CancellationError {}

    let loadsBeforeRecovery = await counters.loads
    let shutdownsBeforeRecovery = await counters.shutdowns
    XCTAssertEqual(loadsBeforeRecovery, 1)
    XCTAssertEqual(shutdownsBeforeRecovery, 1)
    try await runtime.load(newModel)
    let recovered = try await runtime.generateTextStream(
      for: newModel, history: [.init(role: .system, content: "system")], userMessage: "recovered", emit: { _ in })
    XCTAssertEqual(recovered, "fixture response")
    try await runtime.unload()
    let loadsAfterRecovery = await counters.loads
    let shutdownsAfterRecovery = await counters.shutdowns
    XCTAssertEqual(loadsAfterRecovery, 2)
    XCTAssertEqual(shutdownsAfterRecovery, 2)
  }

  func testTextLoadCommitCleanupFailurePoisonsResidency() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let commitGate = Gate()
    let processResidency = TestProcessResidency()
    let first = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      residency: processResidency,
      textLoader: .init(load: { _ in
        await counters.loaded()
        return FailingTextShutdownSession(counters: counters)
      }),
      beforeLoadCommit: { await commitGate.wait() })
    let model = try tinyTextModel()
    try await first.prepare(model)

    let load = Task { try await first.load(model) }
    let commitEntered = await waitForGateEntered(commitGate)
    XCTAssertTrue(commitEntered)
    load.cancel()
    await commitGate.release()
    do {
      try await load.value
      XCTFail("cleanup failure must override cancellation")
    } catch LeapError.nativeFailure {}

    let loadsAfterFailure = await counters.loads
    let shutdownsAfterFailure = await counters.shutdowns
    XCTAssertEqual(loadsAfterFailure, 1)
    XCTAssertEqual(shutdownsAfterFailure, 1)
    let second = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      residency: processResidency,
      textLoader: .init(load: { _ in
        await counters.loaded()
        return TextFixtureSession(counters: counters)
      }))
    do {
      try await second.load(model)
      XCTFail("poisoned residency must reject another text load")
    } catch LeapError.nativeFailure {}
    let textLoadsAfterPoison = await counters.loads
    XCTAssertEqual(textLoadsAfterPoison, 1)
  }

  func testVoiceLoadCommitCleanupFailurePoisonsResidency() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let commitGate = Gate()
    let processResidency = TestProcessResidency()
    let first = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in
        await counters.loaded()
        return FailingShutdownSession(counters: counters)
      }),
      residency: processResidency,
      beforeLoadCommit: { await commitGate.wait() })
    try await first.prepare(fixtureVoiceModel)

    let load = Task { try await first.load(fixtureVoiceModel) }
    let commitEntered = await waitForGateEntered(commitGate)
    XCTAssertTrue(commitEntered)
    load.cancel()
    await commitGate.release()
    do {
      try await load.value
      XCTFail("cleanup failure must override cancellation")
    } catch LeapError.nativeFailure {}

    let loadsAfterFailure = await counters.loads
    let shutdownsAfterFailure = await counters.shutdowns
    XCTAssertEqual(loadsAfterFailure, 1)
    XCTAssertEqual(shutdownsAfterFailure, 2)
    let second = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      residency: processResidency)
    do {
      try await second.load(fixtureVoiceModel)
      XCTFail("poisoned residency must reject another voice load")
    } catch LeapError.nativeFailure {}
    let voiceLoadsAfterPoison = await counters.loads
    XCTAssertEqual(voiceLoadsAfterPoison, 1)
  }

  func testManagedTextLoadCancellationRetainsLeaseUntilDrain() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let gate = Gate()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      textLoader: .init(load: { _ in
        await gate.wait()
        await counters.loaded()
        return TextFixtureSession(counters: counters)
      }))
    let model = try tinyTextModel()
    try await runtime.prepare(model)

    let load = Task { try await runtime.load(model) }
    let loadEntered = await waitForGateEntered(gate)
    XCTAssertTrue(loadEntered)
    load.cancel()
    do {
      try await load.value
      XCTFail("cancelled text load must return cancellation")
    } catch is CancellationError {}

    let drainingReadiness = try await runtime.readiness(for: model)
    XCTAssertEqual(drainingReadiness, .busy)
    await gate.release()
    for _ in 0..<100 {
      if try await runtime.readiness(for: model) == .ready { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let loads = await counters.loads
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(loads, 1)
    XCTAssertEqual(shutdowns, 1)
  }

  func testTextReadinessRequiresTheRequestedResidentRunner() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: Counters()),
      loader: .init(load: { _ in FixtureSession(counters: Counters()) }),
      residency: .shared)

    let readiness = try await runtime.readiness(for: try tinyTextModel())
    XCTAssertEqual(readiness, .missing)
    let manifest = try tinyTextModel().manifest
    XCTAssertThrowsError(
      try LeapTextModel(
        repositoryID: "fixture/local",
        revision: String(repeating: "b", count: 40),
        modelPath: "../model.gguf",
        manifest: manifest)
    ) {
      XCTAssertEqual($0 as? LeapError, .invalidRequest)
    }
  }

  func testRequestBoundaryAcceptsEnglishAndRejectsUnsupportedInput() throws {
    try LeapVoiceRequest.synthesizeEnglish(text: "Small steps help.", voice: .usFemale)
      .validate()
    XCTAssertThrowsError(
      try LeapVoiceRequest.synthesizeEnglish(text: "작은 걸음", voice: .usFemale).validate()
    ) {
      XCTAssertEqual($0 as? LeapError, .unsupportedLanguageOrCapability)
    }
    XCTAssertNoThrow(try LeapAudioInput(samples: [0, 0.25, -0.25], sampleRate: 48_000))
    XCTAssertThrowsError(try LeapAudioInput(samples: [], sampleRate: 48_000))
    XCTAssertThrowsError(try LeapAudioInput(samples: [.nan], sampleRate: 48_000))
    XCTAssertThrowsError(try LeapAudioInput(samples: [1.01], sampleRate: 48_000))
    XCTAssertThrowsError(try LeapAudioInput(samples: [0], sampleRate: 7_999))
    XCTAssertEqual(Set(LeapEnglishVoice.allCases), [.usMale, .usFemale, .ukMale, .ukFemale])
  }

  func testTextGenerationFailsClosedWithoutRunnerOrMessage() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: Counters()),
      loader: .init(load: { _ in FixtureSession(counters: Counters()) }))
    do {
      _ = try await runtime.generateTextStream(
        for: try tinyTextModel(), history: [.init(role: .system, content: "s")], userMessage: "hi", emit: { _ in })
      XCTFail("text generation without a loaded runner must throw")
    } catch let error as LeapError {
      XCTAssertEqual(error, .modelMissing)
    }
    do {
      _ = try await runtime.generateTextStream(
        for: try tinyTextModel(), history: [.init(role: .system, content: "s")], userMessage: "", emit: { _ in })
      XCTFail("empty user message must be rejected before touching the runner")
    } catch let error as LeapError {
      XCTAssertEqual(error, .invalidRequest)
    }
  }

  func testErrorsBridgeWithStablePresentationCodes() {
    let cases: [(LeapError, Int, String)] = [
      (.invalidRequest, 1_001, "invalidRequest"),
      (.unsupportedLanguageOrCapability, 1_002, "unsupportedLanguageOrCapability"),
      (.modelMissing, 1_003, "modelMissing"),
      (.busy, 1_004, "busy"),
      (.insufficientDisk, 1_005, "insufficientDisk"),
      (.invalidArtifact, 1_006, "invalidArtifact"),
      (.invalidRuntimeOutput, 1_007, "invalidRuntimeOutput"),
      (.outputLimitExceeded, 1_008, "outputLimitExceeded"),
      (.generationInterrupted, 1_009, "generationInterrupted"),
      (.generationTimedOut, 1_010, "generationTimedOut"),
      (.generationStalled, 1_011, "generationStalled"),
      (.nativeFailure, 1_012, "nativeFailure"),
    ]
    for (value, code, stableCode) in cases {
      let bridged = value as NSError
      XCTAssertEqual(bridged.domain, LeapError.errorDomain)
      XCTAssertEqual(bridged.code, code)
      XCTAssertEqual(bridged.localizedDescription, value.errorDescription)
      XCTAssertEqual(bridged.userInfo["NativeAgentLeapCode"] as? String, stableCode)
    }
  }

  func testAudioInputUsesOfficialFloatSamplesWithoutContainerConversion() throws {
    let input = try LeapAudioInput(samples: [0, 0.5, -0.5], sampleRate: 16_000)
    XCTAssertEqual(input.sampleRate, 16_000)
    XCTAssertEqual(input.samples, [0, 0.5, -0.5])
    try LeapVoiceRequest.speechToSpeechEnglish(audio: input).validate()
  }

  func testGenerationPolicyHasFiniteNativeAndPayloadBounds() {
    XCTAssertEqual(LeapLimits.maxGenerationTokens, 512)
    XCTAssertEqual(LeapLimits.maxTextBytes, 16_384)
    XCTAssertEqual(LeapLimits.maxOutputSeconds, 120)
    XCTAssertEqual(LeapLimits.maxRepeatedTextChunks, 4)
    XCTAssertEqual(LeapLimits.maxResponseEvents, 2_048)
    XCTAssertEqual(LeapLimits.textContextTokens, 8_192)
    XCTAssertEqual(LeapLimits.maxTextGenerationTokens, 4_096)
    XCTAssertEqual(LeapLimits.maxTextGenerationBytes, 128 * 1_024)
    XCTAssertEqual(LeapLimits.maxTextChunks, 8_192)
  }

  func testEndlessEmptyAndRepeatedEventsHitFiniteBound() async throws {
    for mode in [EndlessEventSession.Mode.empty, .repeated] {
      let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
      let counters = Counters()
      let runtime = LeapRuntime(
        store: store, downloader: FixtureDownloader(counters: counters),
        loader: .init(load: { _ in EndlessEventSession(mode: mode, counters: counters) }),
        watchdog: .init(total: .seconds(2), inactivity: .seconds(1)))
      try await runtime.prepare(fixtureVoiceModel)
      do {
        try await runtime.generate(
          for: fixtureVoiceModel,
          request: .synthesizeEnglish(text: "Repeat.", voice: .usMale), emit: { _ in })
        XCTFail("unbounded (mode) events must fail")
      } catch LeapError.outputLimitExceeded {}
      for _ in 0..<100 {
        if try await runtime.readiness(for: fixtureVoiceModel) == .ready { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      let shutdowns = await counters.shutdowns
      XCTAssertEqual(shutdowns, 1)
    }
  }

  func testPreparePublishesOnceAndWarmRequestsLoadOnce() async throws {
    let root = try temporaryDirectory()
    let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
    let counters = Counters()
    let runtime = LeapRuntime(
      store: store,
      downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in
        await counters.loaded()
        return FixtureSession(counters: counters)
      }),
    )
    let initialReadiness = try await runtime.readiness(for: fixtureVoiceModel)
    XCTAssertEqual(initialReadiness, .missing)
    try await runtime.prepare(fixtureVoiceModel)
    try await runtime.prepare(fixtureVoiceModel)
    let preparedReadiness = try await runtime.readiness(for: fixtureVoiceModel)
    let downloads = await counters.downloads
    XCTAssertEqual(preparedReadiness, .ready)
    XCTAssertEqual(downloads, 1)
    try await runtime.load(fixtureVoiceModel)

    let asr = try await collect(
      runtime.generator(for: fixtureVoiceModel), request: .transcribeEnglish(audio: audio()))
    XCTAssertEqual(
      asr, [.transcriptDelta("Small steps build strong routines."), .completed(try usage())])
    let tts = try await collect(
      runtime.generator(for: fixtureVoiceModel),
      request: .synthesizeEnglish(text: "Hello.", voice: .ukFemale))
    XCTAssertEqual(tts.count, 2)
    let loads = await counters.loads
    XCTAssertEqual(loads, 1)
    try await runtime.unload()
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 1)
  }

  func testMissingModelFailsWithoutNativeLoad() async throws {
    let counters = Counters()
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in
        await counters.loaded()
        return FixtureSession(counters: counters)
      }),
    )
    do {
      _ = try await collect(
        runtime.generator(for: fixtureVoiceModel), request: .transcribeEnglish(audio: audio()))
      XCTFail("missing model must not load")
    } catch LeapError.modelMissing {}
    let loads = await counters.loads
    XCTAssertEqual(loads, 0)
  }

  func testProcessResidencyBlocksSecondRuntime() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let downloader = FixtureDownloader(counters: counters)
    let first = LeapRuntime(
      store: store, downloader: downloader,
      loader: .init(load: { _ in
        await counters.loaded()
        return FixtureSession(counters: counters)
      }),
    )
    let second = LeapRuntime(
      store: store, downloader: downloader,
      loader: .init(load: { _ in
        await counters.loaded()
        return FixtureSession(counters: counters)
      }),
    )
    try await first.prepare(fixtureVoiceModel)
    _ = try await collect(
      first.generator(for: fixtureVoiceModel),
      request: .synthesizeEnglish(text: "One.", voice: .usMale))
    do {
      _ = try await collect(
        second.generator(for: fixtureVoiceModel),
        request: .synthesizeEnglish(text: "Two.", voice: .usMale))
      XCTFail("second resident must be blocked")
    } catch LeapError.busy {}
    try await first.unload()
    _ = try await collect(
      second.generator(for: fixtureVoiceModel),
      request: .synthesizeEnglish(text: "Two.", voice: .usMale))
    try await second.unload()
  }

  func testCancellationQuarantinesNonCooperativeGeneration() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let gate = Gate()
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in
        await counters.loaded()
        return StallingSession(gate: gate, counters: counters)
      }),
    )
    try await runtime.prepare(fixtureVoiceModel)
    let task = Task {
      try await runtime.generate(
        for: fixtureVoiceModel,
        request: .synthesizeEnglish(text: "Wait.", voice: .usFemale), emit: { _ in })
    }
    let generationEntered = await waitForGateEntered(gate)
    XCTAssertTrue(generationEntered)
    task.cancel()
    do {
      try await task.value
      XCTFail("cancel must return")
    } catch is CancellationError {}
    let drainingReadiness = try await runtime.readiness(for: fixtureVoiceModel)
    XCTAssertEqual(drainingReadiness, .busy)
    await gate.release()
    for _ in 0..<100 {
      if try await runtime.readiness(for: fixtureVoiceModel) == .ready { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 1)
  }

  func testMemoryWarningCancelsAndDrainsActiveGeneration() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let gate = Gate()
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in
        await counters.loaded()
        return StallingSession(gate: gate, counters: counters)
      }),
    )
    try await runtime.prepare(fixtureVoiceModel)
    let generation = Task {
      try await runtime.generate(
        for: fixtureVoiceModel,
        request: .synthesizeEnglish(text: "Wait.", voice: .usFemale), emit: { _ in })
    }
    let generationEntered = await waitForGateEntered(gate)
    XCTAssertTrue(generationEntered)
    let warning = Task { try await runtime.handleMemoryWarning() }
    await gate.release()
    do {
      try await warning.value
    } catch {
      XCTFail("lifecycle handler failed: \(String(reflecting: error))")
    }
    do {
      try await generation.value
      XCTFail("memory warning must cancel generation")
    } catch is CancellationError {}
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 1)
    let readiness = try await runtime.readiness(for: fixtureVoiceModel)
    XCTAssertEqual(readiness, .ready)
  }

  func testPinnedBackgroundAndThermalRecoveryPolicy() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in
        await counters.loaded()
        return FixtureSession(counters: counters)
      }),
    )
    try await runtime.prepare(fixtureVoiceModel)
    let request = LeapVoiceRequest.synthesizeEnglish(text: "Policy.", voice: .usFemale)
    try await runtime.generate(for: fixtureVoiceModel, request: request, emit: { _ in })
    try await runtime.handleBackgroundEntry(pinned: true)
    try await runtime.generate(for: fixtureVoiceModel, request: request, emit: { _ in })
    let loadsAfterPinned = await counters.loads
    XCTAssertEqual(loadsAfterPinned, 1)
    try await runtime.handleThermalState(.serious)
    let shutdownsAfterThermal = await counters.shutdowns
    XCTAssertEqual(shutdownsAfterThermal, 1)
    try await runtime.generate(for: fixtureVoiceModel, request: request, emit: { _ in })
    let loadsAfterRecovery = await counters.loads
    XCTAssertEqual(loadsAfterRecovery, 2)
    try await runtime.handleThermalState(.nominal)
    try await runtime.handleBackgroundEntry()
    let shutdownsAfterBackground = await counters.shutdowns
    XCTAssertEqual(shutdownsAfterBackground, 2)
  }

  func testInactivityWatchdogQuarantinesNonCooperativeGeneration() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let gate = Gate()
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in
        await counters.loaded()
        return StallingSession(gate: gate, counters: counters)
      }),
      watchdog: .init(total: .seconds(1), inactivity: .milliseconds(30)))
    try await runtime.prepare(fixtureVoiceModel)
    do {
      try await runtime.generate(
        for: fixtureVoiceModel,
        request: .synthesizeEnglish(text: "Stall.", voice: .usFemale), emit: { _ in })
      XCTFail("inactivity watchdog must fail")
    } catch LeapError.generationStalled {}
    let drainingReadiness = try await runtime.readiness(for: fixtureVoiceModel)
    XCTAssertEqual(drainingReadiness, .busy)
    await gate.release()
    for _ in 0..<100 {
      if try await runtime.readiness(for: fixtureVoiceModel) == .ready { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 1)
  }

  func testTotalWatchdogQuarantinesBeforeInactivityLimit() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let gate = Gate()
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in return StallingSession(gate: gate, counters: counters) }),
      watchdog: .init(total: .milliseconds(30), inactivity: .seconds(1)))
    try await runtime.prepare(fixtureVoiceModel)
    do {
      try await runtime.generate(
        for: fixtureVoiceModel,
        request: .synthesizeEnglish(text: "Timeout.", voice: .usMale), emit: { _ in })
      XCTFail("total watchdog must fail")
    } catch LeapError.generationTimedOut {}
    await gate.release()
    for _ in 0..<100 {
      if try await runtime.readiness(for: fixtureVoiceModel) == .ready { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 1)
  }

  func testGenerationWithoutTerminalFailsClosedAndUnloads() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in NoTerminalSession(counters: counters) }),
    )
    try await runtime.prepare(fixtureVoiceModel)
    do {
      _ = try await collect(
        runtime.generator(for: fixtureVoiceModel), request: .transcribeEnglish(audio: audio()))
      XCTFail("a stream without a terminal must fail")
    } catch LeapError.invalidRuntimeOutput {}
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 1)
    let readiness = try await runtime.readiness(for: fixtureVoiceModel)
    XCTAssertEqual(readiness, .ready)
  }

  func testCancellationQuarantinesNonCooperativeLoad() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let gate = Gate()
    let runtime = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in
        await gate.wait()
        await counters.loaded()
        return FixtureSession(counters: counters)
      }))
    try await runtime.prepare(fixtureVoiceModel)
    let task = Task {
      try await runtime.generate(
        for: fixtureVoiceModel,
        request: .synthesizeEnglish(text: "Wait for load.", voice: .usFemale), emit: { _ in })
    }
    let loadEntered = await waitForGateEntered(gate)
    XCTAssertTrue(loadEntered)
    task.cancel()
    do {
      try await task.value
      XCTFail("cancelled load must return")
    } catch is CancellationError {}
    let drainingReadiness = try await runtime.readiness(for: fixtureVoiceModel)
    XCTAssertEqual(drainingReadiness, .busy)
    await gate.release()
    for _ in 0..<100 {
      if try await runtime.readiness(for: fixtureVoiceModel) == .ready { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let shutdowns = await counters.shutdowns
    XCTAssertEqual(shutdowns, 1)
  }

  func testUnloadFailurePoisonsProcessResidency() async throws {
    let store = try ModelArtifactStore(rootURL: temporaryDirectory(), minimumFreeBytes: 0)
    let counters = Counters()
    let residency = ProcessResidency.shared
    let first = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FailingShutdownSession(counters: counters) }),
      residency: residency)
    try await first.prepare(fixtureVoiceModel)
    _ = try await collect(
      first.generator(for: fixtureVoiceModel),
      request: .synthesizeEnglish(text: "One.", voice: .usMale))
    do {
      try await first.unload()
      XCTFail("unload failure must be visible")
    } catch LeapError.nativeFailure {}
    do {
      _ = try await first.readiness(for: fixtureVoiceModel)
      XCTFail("poisoned runtime must not report ready")
    } catch LeapError.nativeFailure {}
    do {
      _ = try await collect(
        first.generator(for: fixtureVoiceModel),
        request: .synthesizeEnglish(text: "Again.", voice: .usMale))
      XCTFail("same poisoned runtime must not reload")
    } catch LeapError.nativeFailure {}

    let second = LeapRuntime(
      store: store, downloader: FixtureDownloader(counters: counters),
      loader: .init(load: { _ in FixtureSession(counters: counters) }),
      residency: residency)
    do {
      _ = try await collect(
        second.generator(for: fixtureVoiceModel),
        request: .synthesizeEnglish(text: "Two.", voice: .usMale))
      XCTFail("poisoned native residency must remain unavailable")
    } catch LeapError.nativeFailure {}
  }
}

private actor Counters {
  var downloads = 0
  var loads = 0
  var shutdowns = 0
  func downloaded() { downloads += 1 }
  func loaded() { loads += 1 }
  func loadedAndWasFirst() -> Bool {
    let first = loads == 0
    loads += 1
    return first
  }
  func shutdown() { shutdowns += 1 }
}

private final class ArtifactOpenCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func reset() {
    lock.lock()
    count = 0
    lock.unlock()
  }
}

private actor DefaultSelectionDownloader: LeapDownloading {
  private(set) var observed: LeapTextModel?

  func download(
    repositoryID: String,
    revision: String,
    manifest: ArtifactManifest,
    into staging: ArtifactStaging,
    progress: (@Sendable (LeapDownloadProgress) -> Void)?
  ) async throws {
    observed = try LeapTextModel(
      repositoryID: repositoryID, revision: revision,
      modelPath: manifest.files[0].path, manifest: manifest)
    throw LeapError.nativeFailure
  }
}

private struct FixtureDownloader: LeapDownloading {
  let counters: Counters
  func download(
    repositoryID: String,
    revision: String,
    manifest: ArtifactManifest,
    into staging: ArtifactStaging,
    progress: (@Sendable (LeapDownloadProgress) -> Void)?
  ) async throws {
    await counters.downloaded()
    for file in manifest.files {
      let value = Data("fixture".utf8)
      try value.write(to: staging.directoryURL.appending(path: file.path))
    }
  }
}

private final class FixtureSession: LeapVoiceSession, @unchecked Sendable {
  let counters: Counters
  init(counters: Counters) { self.counters = counters }
  func generate(
    request: LeapVoiceRequest,
    emit: @escaping @Sendable (LeapVoiceEvent) -> Void
  ) async throws {
    switch request {
    case .transcribeEnglish: emit(.transcriptDelta("Small steps build strong routines."))
    case .synthesizeEnglish: emit(.pcm(samples: [0.1, -0.1], sampleRate: 24_000))
    case .speechToSpeechEnglish:
      emit(.textDelta("Take one small step."))
      emit(.pcm(samples: [0.1], sampleRate: 24_000))
    }
    emit(.completed(try usage()))
  }
  func shutdown() async throws { await counters.shutdown() }
}

private actor TextHistoryRecorder {
  struct Invocation: Sendable, Equatable {
    let history: [LeapTextMessage]
    let userMessage: String
    let outputFormat: ModelOutputFormat
  }

  private var invocation: Invocation?

  func record(history: [LeapTextMessage], userMessage: String, outputFormat: ModelOutputFormat) {
    invocation = Invocation(history: history, userMessage: userMessage, outputFormat: outputFormat)
  }

  func value() -> Invocation? { invocation }
}

private final class RecordingTextSession: LeapTextSession, @unchecked Sendable {
  let recorder: TextHistoryRecorder
  let jsonChunks: [String]
  init(recorder: TextHistoryRecorder, jsonChunks: [String] = [#"{"question":"What happened?"}"#]) {
    self.recorder = recorder
    self.jsonChunks = jsonChunks
  }

  func generate(
    history: [LeapTextMessage],
    userMessage: String,
    outputFormat: ModelOutputFormat,
    emit: @escaping @Sendable (LeapTextEvent) -> Void
  ) async throws {
    await recorder.record(history: history, userMessage: userMessage, outputFormat: outputFormat)
    switch outputFormat {
    case .text: emit(.text("fixture response"))
    case .jsonObject: for chunk in jsonChunks { emit(.text(chunk)) }
    }
    emit(.completed)
  }

  func shutdown() async throws {}
}

private final class TextFixtureSession: LeapTextSession, @unchecked Sendable {
  let counters: Counters
  init(counters: Counters) { self.counters = counters }

  func generate(
    history: [LeapTextMessage],
    userMessage: String,
    outputFormat: ModelOutputFormat,
    emit: @escaping @Sendable (LeapTextEvent) -> Void
  ) async throws {
    emit(.text("fixture "))
    emit(.text("response"))
    emit(.completed)
  }

  func shutdown() async throws { await counters.shutdown() }
}

private final class FailingTextShutdownSession: LeapTextSession, @unchecked Sendable {
  let counters: Counters
  init(counters: Counters) { self.counters = counters }

  func generate(
    history: [LeapTextMessage],
    userMessage: String,
    outputFormat: ModelOutputFormat,
    emit: @escaping @Sendable (LeapTextEvent) -> Void
  ) async throws {
    emit(.text("fixture response"))
    emit(.completed)
  }

  func shutdown() async throws {
    await counters.shutdown()
    throw FixtureError.shutdown
  }
}

private final class BlockingShutdownTextSession: LeapTextSession, @unchecked Sendable {
  let gate: Gate
  let counters: Counters

  init(gate: Gate, counters: Counters) {
    self.gate = gate
    self.counters = counters
  }

  func generate(
    history: [LeapTextMessage],
    userMessage: String,
    outputFormat: ModelOutputFormat,
    emit: @escaping @Sendable (LeapTextEvent) -> Void
  ) async throws {
    emit(.text("fixture "))
    emit(.text("response"))
    emit(.completed)
  }

  func shutdown() async throws {
    await gate.wait()
    await counters.shutdown()
  }
}

private final class TextStallingSession: LeapTextSession, @unchecked Sendable {
  let gate: Gate
  let counters: Counters
  init(gate: Gate, counters: Counters) {
    self.gate = gate
    self.counters = counters
  }

  func generate(
    history: [LeapTextMessage],
    userMessage: String,
    outputFormat: ModelOutputFormat,
    emit: @escaping @Sendable (LeapTextEvent) -> Void
  ) async throws {
    await gate.wait()
  }

  func shutdown() async throws {
    try Task.checkCancellation()
    await counters.shutdown()
  }
}

private actor Gate {
  private var open = false
  private var entered = false
  func wait() async {
    entered = true
    while !open { try? await Task.sleep(for: .milliseconds(10)) }
  }
  func hasEntered() -> Bool { entered }
  func release() { open = true }
}

// A bounded event wait makes test progress depend on the gate's entered event,
// not on a scheduler-specific sleep that may race a native boundary.
private func waitForGateEntered(_ gate: Gate) async -> Bool {
  for _ in 0..<400 {
    if await gate.hasEntered() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await gate.hasEntered()
}

private final class TestProcessResidency: LeapProcessResidency, @unchecked Sendable {
  private let lock = NSLock()
  private var owner: UUID?
  private var poisoned = false

  func isPoisoned() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return poisoned
  }

  func claim(_ candidate: UUID) throws -> any LeapProcessResidencyLease {
    lock.lock()
    guard !poisoned, owner == nil else {
      lock.unlock()
      throw ProcessResidencyError.busy
    }
    owner = candidate
    lock.unlock()
    return TestProcessResidencyLease(
      close: { [weak self] in self?.release(candidate) },
      poison: { [weak self] objects in self?.poison(candidate, retaining: objects) })
  }

  private func release(_ candidate: UUID) {
    lock.lock()
    defer { lock.unlock() }
    if owner == candidate { owner = nil }
  }

  private func poison(_ candidate: UUID, retaining objects: [AnyObject]) {
    lock.lock()
    defer { lock.unlock() }
    guard owner == candidate else { return }
    poisoned = true
    _ = objects
  }
}

private final class TestProcessResidencyLease: LeapProcessResidencyLease,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let closeAction: () -> Void
  private let poisonAction: ([AnyObject]) -> Void
  private var closed = false

  init(close: @escaping () -> Void, poison: @escaping ([AnyObject]) -> Void) {
    closeAction = close
    poisonAction = poison
  }

  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    lock.unlock()
    closeAction()
  }

  func poison(retaining objects: [AnyObject]) {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    lock.unlock()
    poisonAction(objects)
  }

  deinit { close() }
}

private final class StallingSession: LeapVoiceSession, @unchecked Sendable {
  let gate: Gate
  let counters: Counters
  init(gate: Gate, counters: Counters) {
    self.gate = gate
    self.counters = counters
  }
  func generate(
    request: LeapVoiceRequest,
    emit: @escaping @Sendable (LeapVoiceEvent) -> Void
  ) async throws { await gate.wait() }
  func shutdown() async throws { await counters.shutdown() }
}

private final class FailingShutdownSession: LeapVoiceSession, @unchecked Sendable {
  let counters: Counters
  init(counters: Counters) { self.counters = counters }
  func generate(
    request: LeapVoiceRequest,
    emit: @escaping @Sendable (LeapVoiceEvent) -> Void
  ) async throws {
    emit(.pcm(samples: [0.1], sampleRate: 24_000))
    emit(.completed(try usage()))
  }
  func shutdown() async throws {
    await counters.shutdown()
    throw FixtureError.shutdown
  }
}

private final class NoTerminalSession: LeapVoiceSession, @unchecked Sendable {
  let counters: Counters
  init(counters: Counters) { self.counters = counters }
  func generate(
    request: LeapVoiceRequest,
    emit: @escaping @Sendable (LeapVoiceEvent) -> Void
  ) async throws {
    emit(.transcriptDelta("partial"))
  }
  func shutdown() async throws { await counters.shutdown() }
}

private final class EndlessEventSession: LeapVoiceSession, @unchecked Sendable {
  enum Mode: Sendable { case empty, repeated }
  let mode: Mode
  let counters: Counters

  init(mode: Mode, counters: Counters) {
    self.mode = mode
    self.counters = counters
  }

  func generate(
    request: LeapVoiceRequest,
    emit: @escaping @Sendable (LeapVoiceEvent) -> Void
  ) async throws {
    while !Task.isCancelled {
      switch mode {
      case .empty: emit(.textDelta(""))
      case .repeated: emit(.textDelta("repeat"))
      }
      await Task.yield()
    }
  }

  func shutdown() async throws { await counters.shutdown() }
}

private enum FixtureError: Error { case shutdown }

private func collect(
  _ generator: LeapVoiceGenerator,
  request: LeapVoiceRequest
) async throws -> [LeapVoiceEvent] {
  var events: [LeapVoiceEvent] = []
  for try await event in generator.events(for: request) { events.append(event) }
  return events
}

private func usage() throws -> LeapVoiceUsage {
  try LeapVoiceUsage(promptTokens: 1, completionTokens: 2, tokensPerSecond: 20)
}

private func audio() -> LeapAudioInput {
  try! LeapAudioInput(samples: [0, 0.1, -0.1], sampleRate: 16_000)
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(
    path: "native-agent-leap-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func tinyManifest() throws -> ArtifactManifest {
  let value = Data("fixture".utf8)
  let digest = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
  return try ArtifactManifest(
    artifactID: "leap-fixture",
    files: [
      try ArtifactEntry(
        path: "model.bin", byteCount: UInt64(value.count),
        sha256: ArtifactDigest(rawValue: digest)!)
    ])
}

private func publishFixture(
  _ store: ModelArtifactStore,
  for model: LeapTextModel
) async throws {
  let staging = try await store.beginStaging(for: model.manifest)
  try Data("fixture".utf8).write(to: staging.directoryURL.appending(path: model.modelPath))
  let lease = try await store.publish(staging)
  lease.close()
}

private func tinyVoiceModel() throws -> LeapVoiceModel {
  return try LeapVoiceModel(
    repositoryID: "fixture/local",
    revision: String(repeating: "a", count: 40),
    manifest: try tinyManifest())
}

private let fixtureVoiceModel = try! tinyVoiceModel()

private func tinyTextModel(
  artifactID: String = "text-fixture",
  displayName: String? = nil,
  revision: String = String(repeating: "b", count: 40)
) throws -> LeapTextModel {
  let value = Data("fixture".utf8)
  let digest = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
  let manifest = try ArtifactManifest(
    artifactID: artifactID,
    files: [
      try ArtifactEntry(
        path: "model.gguf", byteCount: UInt64(value.count),
        sha256: ArtifactDigest(rawValue: digest)!)
    ])
  return try LeapTextModel(
    repositoryID: "fixture/local", revision: revision,
    modelPath: "model.gguf", manifest: manifest, displayName: displayName)
}
