import EmbeddingCore
import Foundation
import Testing
@testable import LiteRTEmbeddingProvider

private actor ControlledNativeCall {
  var started = false
  var completed = false
  var released = false
  var releasedEarly = false
  var closeCount = 0
  private var continuation: CheckedContinuation<[Float], Never>?
  func compute(_ text: String) async -> [Float] {
    started = true
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
