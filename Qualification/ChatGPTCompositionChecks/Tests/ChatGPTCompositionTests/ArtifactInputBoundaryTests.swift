@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Darwin
import Foundation
import Testing
import NativeAgentDomain
import LanguageModelCore

@Suite("Descriptor-relative current-session artifact input")
struct ArtifactInputBoundaryTests {
  private func withRoot(_ body: (URL, ToolExecutionContext) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/layer-tests/artifacts"), withIntermediateDirectories: true)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record(error, "Temporary artifact fixture cleanup failed") }
    }
    try body(root, PNGTestFixture.context(root: root))
  }

  @Test func currentSessionExactBytesAndTightLimitAreAccepted() throws {
    try withRoot { root, context in
      let bytes = Data("immutable plan".utf8)
      let path = "sessions/layer-tests/artifacts/plan.json"
      try bytes.write(to: root.appendingPathComponent(path))
      let read = try ChatGPTSessionArtifactInputResolver.read(relativePath: path,
        expectedSHA256: SHA256HexDigest.digest(bytes), context: context, maximumBytes: bytes.count)
      #expect(read == bytes)
      #expect(throws: AgentError.self) {
        _ = try ChatGPTSessionArtifactInputResolver.read(relativePath: path,
          expectedSHA256: SHA256HexDigest.digest(bytes), context: context, maximumBytes: bytes.count - 1)
      }
    }
  }

  @Test func staleDigestEmptyFileAndMalformedDigestNeverReadAsSuccess() throws {
    try withRoot { root, context in
      let path = "sessions/layer-tests/artifacts/input.png"
      let bytes = PNGTestFixture.png()
      try bytes.write(to: root.appendingPathComponent(path))
      for digest in [String(repeating: "0", count: 64), String(repeating: "A", count: 64), "short"] {
        #expect(throws: AgentError.self) {
          _ = try ChatGPTSessionArtifactInputResolver.read(relativePath: path, expectedSHA256: digest, context: context)
        }
      }
      try Data().write(to: root.appendingPathComponent(path))
      #expect(throws: AgentError.self) {
        _ = try ChatGPTSessionArtifactInputResolver.read(relativePath: path,
          expectedSHA256: SHA256HexDigest.digest(Data()), context: context)
      }
    }
  }

  @Test func traversalOtherSessionAbsoluteAndEmptyComponentsAreRejected() throws {
    try withRoot { _, context in
      let paths = ["sessions/other/artifacts/x", "/sessions/layer-tests/artifacts/x",
        "sessions/layer-tests/artifacts/../x", "sessions/layer-tests/artifacts//x",
        "sessions/layer-tests/artifacts/./x", "sessions/layer-tests/artifacts/x\0y", "sessions\\layer-tests\\artifacts\\x"]
      for path in paths {
        #expect(throws: AgentError.self) {
          _ = try ChatGPTSessionArtifactInputResolver.read(relativePath: path,
            expectedSHA256: String(repeating: "a", count: 64), context: context)
        }
      }
    }
  }

  @Test func symlinkFileAndDirectoryCannotRedirectTheOpenDescriptor() throws {
    try withRoot { root, context in
      let bytes = PNGTestFixture.png()
      let actual = root.appendingPathComponent("actual.png")
      try bytes.write(to: actual)
      let filePath = "sessions/layer-tests/artifacts/link.png"
      try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(filePath), withDestinationURL: actual)
      let directoryPath = "sessions/layer-tests/artifacts/redirect"
      try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(directoryPath), withDestinationURL: root)
      for path in [filePath, directoryPath + "/actual.png"] {
        #expect(throws: AgentError.self) {
          _ = try ChatGPTSessionArtifactInputResolver.read(relativePath: path,
            expectedSHA256: SHA256HexDigest.digest(bytes), context: context)
        }
      }
    }
  }

  @Test func fifoIsRejectedWithoutBlockingOnAWriter() throws {
    try withRoot { root, context in
      let path = "sessions/layer-tests/artifacts/pipe"
      let status = root.appendingPathComponent(path).path.withCString { mkfifo($0, mode_t(0o600)) }
      try #require(status == 0)
      #expect(throws: AgentError.self) {
        _ = try ChatGPTSessionArtifactInputResolver.read(relativePath: path,
          expectedSHA256: String(repeating: "a", count: 64), context: context)
      }
    }
  }
}
