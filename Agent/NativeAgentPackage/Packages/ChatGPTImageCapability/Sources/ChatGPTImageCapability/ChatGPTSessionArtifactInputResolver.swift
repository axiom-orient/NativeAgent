import Darwin
import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
import LanguageModelCore

/// Reads an immutable byte snapshot from the current session without following
/// symlinks. The opened descriptors own path resolution through the entire read.
enum ChatGPTSessionArtifactInputResolver {
  private static let readChunkBytes = 64 * 1_024

  static func read(
    relativePath: String,
    expectedSHA256: String,
    context: ToolExecutionContext,
    maximumBytes: Int = ChatGPTImageClient.maximumInputImageBytes
  ) throws -> Data {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard (1...ChatGPTImageClient.maximumInputImageBytes).contains(maximumBytes),
      relativePath.utf8.count <= 1_024, components.count >= 4,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !relativePath.contains("\0"), !relativePath.contains("\\"),
      expectedSHA256.utf8.count == 64,
      expectedSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw AgentError.invalidToolCall("Artifact image reference is invalid") }
    guard components[0] == "sessions", components[1] == Substring(context.sessionID),
      components[2] == "artifacts"
    else { throw AgentError.accessDenied("Image artifact must belong to the current Agent session") }

    let root = context.sandboxRootURL.standardizedFileURL.resolvingSymlinksInPath()
    guard root.isFileURL else { throw AgentError.invalidToolCall("Artifact root must be a file URL") }
    var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw AgentError.accessDenied("Cannot open the artifact root") }
    defer { close(directory) }
    for component in components.dropLast() {
      let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else {
        throw AgentError.accessDenied("Artifact directory must exist and must not be a symbolic link")
      }
      close(directory)
      directory = next
    }
    // Nonblocking open prevents a substituted FIFO from hanging before fstat.
    let descriptor = openat(directory, String(components.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw AgentError.accessDenied("Cannot open the artifact image") }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size > 0, info.st_size <= maximumBytes
    else { throw AgentError.invalidToolCall("Referenced image artifact is not a bounded regular file") }

    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    var buffer = [UInt8](repeating: 0, count: readChunkBytes)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, min(readChunkBytes, maximumBytes - data.count + 1))
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw AgentError.persistenceFailure("Unable to read the artifact image")
      }
      if count == 0 { break }
      guard count <= maximumBytes - data.count else {
        throw AgentError.invalidToolCall("Referenced image artifact exceeds its byte limit")
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard data.count == info.st_size, SHA256HexDigest.digest(data) == expectedSHA256 else {
      throw AgentError.invalidToolCall("Referenced image artifact does not match its digest")
    }
    return data
  }
}
