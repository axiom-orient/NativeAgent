import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Serializes the short profile mutations owned by `AgentWorkspace`.
///
/// The process mutex covers independent `AgentWorkspace` instances in one host.
/// The advisory file lock extends the same ownership boundary to cooperating
/// processes that share the Agent data root.
struct AgentWorkspaceMutationFence: Sendable {
  private static let processMutex = NSLock()

  let agentsRootURL: URL

  func withExclusiveMutation<T>(_ operation: String, _ body: () throws -> T) throws -> T {
    Self.processMutex.lock()
    defer { Self.processMutex.unlock() }

    let lock = try AgentWorkspaceFileLock(agentsRootURL: agentsRootURL, operation: operation)
    defer { lock.unlock() }
    return try body()
  }
}

private struct AgentWorkspaceMutationLockError: Error, LocalizedError {
  let operation: String
  let cause: String
  let context: [String: String]

  var errorDescription: String? {
    let details = context.keys.sorted().map { "\($0)=\(context[$0] ?? "")" }.joined(separator: ", ")
    if details.isEmpty {
      return "Agent workspace mutation lock failed. operation=\(operation); cause=\(cause)"
    }
    return
      "Agent workspace mutation lock failed. operation=\(operation); cause=\(cause); context=\(details)"
  }
}

private final class AgentWorkspaceFileLock: @unchecked Sendable {
  private let handle: FileHandle
  private var locked = true

  init(agentsRootURL: URL, operation: String) throws {
    do {
      try FileManager.default.createDirectory(
        at: agentsRootURL,
        withIntermediateDirectories: true
      )
    } catch {
      throw AgentWorkspaceMutationLockError(
        operation: operation,
        cause: "create-agents-root: \(error.localizedDescription)",
        context: ["path": agentsRootURL.path]
      )
    }

    let rootDescriptor = agentsRootURL.path.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard rootDescriptor >= 0 else {
      throw lockError(operation: operation, cause: "open-agents-root", path: agentsRootURL.path)
    }
    defer { agentWorkspaceClose(rootDescriptor) }

    let descriptor = ".agent-mutation.lock".withCString {
      openat(
        rootDescriptor,
        $0,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      throw lockError(operation: operation, cause: "open-lock-file", path: agentsRootURL.path)
    }

    var information = stat()
    guard fstat(descriptor, &information) == 0,
      information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      information.st_nlink == 1
    else {
      agentWorkspaceClose(descriptor)
      throw AgentWorkspaceMutationLockError(
        operation: operation,
        cause: "invalid-lock-file",
        context: ["path": agentsRootURL.appendingPathComponent(".agent-mutation.lock").path]
      )
    }

    guard flock(descriptor, LOCK_EX) == 0 else {
      let error = lockError(operation: operation, cause: "flock", path: agentsRootURL.path)
      agentWorkspaceClose(descriptor)
      throw error
    }

    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  func unlock() {
    guard locked else { return }
    _ = flock(handle.fileDescriptor, LOCK_UN)
    try? handle.close()
    locked = false
  }

  deinit {
    unlock()
  }
}

private func lockError(operation: String, cause: String, path: String)
  -> AgentWorkspaceMutationLockError
{
  AgentWorkspaceMutationLockError(
    operation: operation,
    cause: "\(cause): errno=\(errno)",
    context: ["path": path]
  )
}

private func agentWorkspaceClose(_ descriptor: Int32) {
  #if canImport(Darwin)
    _ = Darwin.close(descriptor)
  #else
    _ = Glibc.close(descriptor)
  #endif
}
