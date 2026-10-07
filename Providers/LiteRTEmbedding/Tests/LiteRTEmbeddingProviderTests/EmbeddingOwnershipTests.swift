import EmbeddingCore
import Foundation
import ModelArtifactStore
import Testing
@testable import LiteRTEmbeddingProvider

private actor ControlledNativeCall {
  var started = false
  var completed = false
  var released = false
  var releasedEarly = false
  var closeCount = 0
  var callCount = 0
  private var continuation: CheckedContinuation<[Float], Never>?
  func compute(_ text: String) async -> [Float] {
    started = true
    callCount += 1
    return await withCheckedContinuation { continuation = $0 }
  }
  func finish() {
    completed = true
    continuation?.resume(returning: Array(repeating: 1, count: 768))
    continuation = nil
  }
  func close() {
    releasedEarly = !completed
    released = true
    closeCount += 1
  }
}

@Test func frozenPromptDialectUsesModelCardAndNeverLiteRTExampleDialect() throws {
  #expect(try EmbeddingGemma2.formattedText(for: .query("  오늘 일정\n")) == "task: search result | query: 오늘 일정")
  #expect(try EmbeddingGemma2.formattedText(for: .document(text: " 내용 ")) == "title: none | text: 내용")
  #expect(try EmbeddingGemma2.formattedText(for: .document(text: "본문", title: "제목")) == "title: 제목 | text: 본문")
  for input: EmbeddingInput in [.query("  "), .query("a\0b"), .document(text: ""), .document(text: "a", title: "\0")] {
    #expect(throws: EmbeddingFailure.invalidInput) { try EmbeddingGemma2.formattedText(for: input) }
  }
}

@Test func cancellationJoinsNativeBeforeReuse() async throws {
  let call = ControlledNativeCall()
  let model = LiteRTEmbeddingModel(compute: { await call.compute($0) }, close: { await call.close() })
  let request = Task { try await model.embed(.query("취소")) }
  while !(await call.started) { await Task.yield() }
  request.cancel()
  #expect(await model.status() == .running)
  await #expect(throws: EmbeddingFailure.busy) { try await model.embed(.query("겹침")) }
  await call.finish()
  await #expect(throws: CancellationError.self) { try await request.value }
  #expect(await model.status() == .ready)
  try await model.shutdown()
  #expect(await call.closeCount == 1)
  #expect(!(await call.releasedEarly))
}

@Test func shutdownClosesIntakeAndDrainsBeforeSingleRelease() async throws {
  let call = ControlledNativeCall()
  let model = LiteRTEmbeddingModel(compute: { await call.compute($0) }, close: { await call.close() })
  let request = Task { try await model.embed(.query("종료")) }
  while !(await call.started) { await Task.yield() }
  let shutdown = Task { try await model.shutdown() }
  while await model.status() != .closing { await Task.yield() }
  shutdown.cancel()
  #expect(!(await call.released))
  await #expect(throws: EmbeddingFailure.closed) { try await model.embed(.query("늦은 요청")) }
  let secondShutdown = Task { try await model.shutdown() }
  await call.finish()
  await #expect(throws: CancellationError.self) { try await request.value }
  try await shutdown.value
  try await secondShutdown.value
  #expect(await model.status() == .closed)
  #expect(await call.closeCount == 1)
  #expect(!(await call.releasedEarly))
}

@Test func releaseFailureRemainsSticky() async throws {
  let model = LiteRTEmbeddingModel(compute: { _ in [] }, close: { throw EmbeddingFailure.nativeFailure(code: 13) })
  for _ in 0..<2 {
  await #expect(throws: EmbeddingFailure.nativeFailure(code: 13)) { try await model.shutdown() }
    #expect(await model.status() == .failed)
  await #expect(throws: EmbeddingFailure.closed) { try await model.embed(.query("재사용")) }
  }
}


@Test func rejectsRemoteArtifactBeforeNativeIO() async {
  await #expect(throws: EmbeddingFailure.invalidInput) {
    try await LiteRTEmbeddingModel.load(
      modelURL: URL(string: "https://example.com/model.litertlm")!,
      cacheDirectory: FileManager.default.temporaryDirectory)
  }
}

#if os(macOS)
@Test func rejectsWrongArtifactSizeAndDigestBeforeEngineCreation() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  do {
    let fileURL = directory.appendingPathComponent("wrong.litertlm")
    try Data([0]).write(to: fileURL)
    await #expect(throws: EmbeddingFailure.artifactMismatch) {
      try await LiteRTEmbeddingModel.load(modelURL: fileURL, cacheDirectory: directory)
    }
    let file = try FileHandle(forWritingTo: fileURL)
    try file.truncate(atOffset: UInt64(EmbeddingGemma2.artifactByteCount))
    try file.close()
    await #expect(throws: EmbeddingFailure.artifactMismatch) {
      try await LiteRTEmbeddingModel.load(modelURL: fileURL, cacheDirectory: directory)
    }
  } catch {
    let failure = error
    try FileManager.default.removeItem(at: directory)
    throw failure
  }
  try FileManager.default.removeItem(at: directory)
}
#endif

@Test func batchValidatesAllInputsBeforeAnyNativeCall() async throws {
  let call = ControlledNativeCall()
  let model = LiteRTEmbeddingModel(compute: { await call.compute($0) }, close: { await call.close() })
  await #expect(throws: EmbeddingFailure.invalidInput) { try await model.embed([.query("valid"), .query(" ")]) }
  await #expect(throws: EmbeddingFailure.invalidInput) { try await model.embed([]) }
  await #expect(throws: EmbeddingFailure.invalidInput) { try await model.embed(Array(repeating: .query("x"), count: 65)) }
  #expect(await call.callCount == 0)
}

@Test func cancelledBatchJoinsItsCallAndDoesNotStartFollowingInputs() async throws {
  let call = ControlledNativeCall()
  let model = LiteRTEmbeddingModel(compute: { await call.compute($0) }, close: { await call.close() })
  let request = Task { try await model.embed([.query("first"), .query("second")]) }
  while !(await call.started) { await Task.yield() }
  await #expect(throws: EmbeddingFailure.busy) { try await model.embed(.query("overlap")) }
  request.cancel()
  await call.finish()
  await #expect(throws: CancellationError.self) { try await request.value }
  #expect(await call.callCount == 1)
  #expect(await model.status() == .ready)
  try await model.shutdown()
}

@Test func selectedMRLDimensionsAreNormalizedWithoutProfileMixing() async throws {
  for dimension in EmbeddingGemma2Dimensions.allCases {
    let profile = EmbeddingGemma2.profile(for: dimension)
    let model = LiteRTEmbeddingModel(profile: profile, compute: { _ in Array(repeating: 1, count: 768) }, close: {})
    let vectors = try await model.embed([.document(text: "document"), .query("query")])
    #expect(vectors.count == 2)
    #expect(vectors.allSatisfy { $0.values.count == dimension.rawValue })
    #expect(abs(try vectors[0].cosineSimilarity(to: vectors[1]) - 1) < 0.0001)
    if dimension != .d256 {
      #expect(throws: EmbeddingFailure.incompatibleProfile) { try vectors[0].validate(for: EmbeddingGemma2.profile) }
    }
    try await model.shutdown()
  }
}

@Test func artifactPreparationNeverPublishesWrongDownloadedBytes() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
  await #expect(throws: ArtifactStoreError.sizeMismatch) {
    try await EmbeddingGemma2.prepare(in: store) { destination in
      try Data("wrong artifact".utf8).write(to: destination)
    }
  }
  await #expect(throws: ArtifactStoreError.missingFile) { try await store.open(EmbeddingGemma2.artifactManifest) }
}

@Test func corruptCacheIsNotSilentlyRedownloaded() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try ModelArtifactStore(rootURL: root, minimumFreeBytes: 0)
  let manifest = EmbeddingGemma2.artifactManifest
  let directory = root.appendingPathComponent("artifacts").appendingPathComponent(manifest.artifactID)
    .appendingPathComponent(manifest.manifestDigest.rawValue)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data("corrupt cache".utf8).write(to: directory.appendingPathComponent(EmbeddingGemma2.artifactFilename))
  await #expect(throws: ArtifactStoreError.sizeMismatch) {
    try await EmbeddingGemma2.prepare(in: store) { _ in Issue.record("Corrupt cache must not trigger download") }
  }
}

@Test func failedBatchHasNoPartialResultAndRestoresAdmission() async throws {
  let model = LiteRTEmbeddingModel(compute: { text in
    if text.contains("fail-me") { throw EmbeddingFailure.nativeFailure(code: 7) }
    return Array(repeating: 1, count: 768)
  }, close: {})
  await #expect(throws: EmbeddingFailure.nativeFailure(code: 7)) {
    try await model.embed([.query("valid"), .query("fail-me")])
  }
  #expect(await model.status() == .ready)
  let reused = try await model.embed(.query("reuse"))
  #expect(reused.values.count == 256)
  try await model.shutdown()
}
