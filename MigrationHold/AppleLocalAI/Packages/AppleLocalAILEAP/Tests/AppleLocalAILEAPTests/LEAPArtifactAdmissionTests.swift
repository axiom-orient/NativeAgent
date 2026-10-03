import CryptoKit
import Foundation
import Testing
@testable import AppleLocalAILEAP

@Suite("LEAP cached artifact admission")
struct LEAPArtifactAdmissionTests {
  @Test func verifiedCacheDoesNotRequireDownloadDiskReserve() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("verified existing artifact".utf8)
    let file = LEAPArtifactFile(
      fileName: "fixture.gguf",
      remoteURL: try #require(URL(string: "https://example.invalid/never-dispatched")),
      byteCount: UInt64(bytes.count),
      sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    let destination = root.appending(path: file.fileName, directoryHint: .notDirectory)
    try bytes.write(to: destination)
    // An acquisition preflight with .max always overflows its safety reserve.
    // A valid existing cache must take the no-download path instead.
    let paths = try await LEAPArtifactStore.prepare(
      files: [file], rootURL: root, minimumFreeBytes: .max, progress: nil)
    #expect(paths == [destination])
    #expect(try Data(contentsOf: destination) == bytes)
  }

  @Test func preCancelledPrepareCannotReturnAnEmptySuccess() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await LEAPArtifactStore.prepare(
        files: [], rootURL: FileManager.default.temporaryDirectory,
        minimumFreeBytes: 0, progress: nil)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
