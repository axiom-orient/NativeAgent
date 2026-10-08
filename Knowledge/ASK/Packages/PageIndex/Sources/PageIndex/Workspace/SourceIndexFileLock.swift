import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum SourceIndexFileLock {
  static func withSharedLock<T>(
    at lockURL: URL,
    label: String,
    _ body: () throws -> T
  ) throws -> T {
    let descriptor = open(lockURL.path, O_RDONLY)
    guard descriptor >= 0 else {
      guard errno == ENOENT else {
        throw ASKPageIndexError.invalidArguments(
          "unable to open \(label) lock for reading: \(lockURL.path) errno=\(errno)"
        )
      }
      return try body()
    }
    guard flock(descriptor, LOCK_SH) == 0 else {
      let code = errno
      let closeFailed = close(descriptor) != 0
      let suffix = closeFailed ? "; closing lock failed" : ""
      throw ASKPageIndexError.invalidArguments(
        "unable to acquire \(label) shared lock: \(lockURL.path) errno=\(code)\(suffix)"
      )
    }
    let result: Result<T, any Error>
    do {
      result = .success(try body())
    } catch {
      result = .failure(error)
    }
    var cleanupFailures: [String] = []
    if flock(descriptor, LOCK_UN) != 0 { cleanupFailures.append("unlock") }
    if close(descriptor) != 0 { cleanupFailures.append("close") }
    guard cleanupFailures.isEmpty else {
      let cleanup = cleanupFailures.joined(separator: ", ")
      switch result {
      case .success:
        throw ASKPageIndexError.invalidArguments(
          "\(label) shared lock cleanup failed: \(cleanup): \(lockURL.path)"
        )
      case .failure(let error):
        throw ASKPageIndexError.invalidArguments(
          "\(label) shared lock operation failed [\(error)]; cleanup failed [\(cleanup)]: \(lockURL.path)"
        )
      }
    }
    return try result.get()
  }

  static func withExclusiveLock<T>(
    at lockURL: URL,
    label: String,
    _ body: () throws -> T
  ) throws -> T {
    try FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else {
      throw ASKPageIndexError.invalidArguments(
        "unable to open \(label) lock: \(lockURL.path) errno=\(errno)"
      )
    }
    guard flock(descriptor, LOCK_EX) == 0 else {
      let code = errno
      let closeFailed = close(descriptor) != 0
      let suffix = closeFailed ? "; closing lock failed" : ""
      throw ASKPageIndexError.invalidArguments(
        "unable to acquire \(label) lock: \(lockURL.path) errno=\(code)\(suffix)"
      )
    }
    let result: Result<T, any Error>
    do {
      try writeOwner(descriptor: descriptor, label: label, lockURL: lockURL)
      result = .success(try body())
    } catch {
      result = .failure(error)
    }
    var cleanupFailures: [String] = []
    if ftruncate(descriptor, 0) != 0 { cleanupFailures.append("truncate") }
    if flock(descriptor, LOCK_UN) != 0 { cleanupFailures.append("unlock") }
    if close(descriptor) != 0 { cleanupFailures.append("close") }
    guard cleanupFailures.isEmpty else {
      let cleanup = cleanupFailures.joined(separator: ", ")
      switch result {
      case .success:
        throw ASKPageIndexError.invalidArguments(
          "\(label) lock cleanup failed: \(cleanup): \(lockURL.path)"
        )
      case .failure(let error):
        throw ASKPageIndexError.invalidArguments(
          "\(label) lock operation failed [\(error)]; cleanup failed [\(cleanup)]: \(lockURL.path)"
        )
      }
    }
    return try result.get()
  }

  private static func writeOwner(
    descriptor: Int32,
    label: String,
    lockURL: URL
  ) throws {
    guard ftruncate(descriptor, 0) == 0 else {
      throw ASKPageIndexError.invalidArguments(
        "unable to truncate \(label) lock: \(lockURL.path) errno=\(errno)"
      )
    }
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
      throw ASKPageIndexError.invalidArguments(
        "unable to seek \(label) lock: \(lockURL.path) errno=\(errno)"
      )
    }

    let owner = "\(getpid())"
    let byteCount = owner.utf8.count
    let written = owner.withCString { pointer in
      write(descriptor, pointer, byteCount)
    }
    guard written == byteCount else {
      throw ASKPageIndexError.invalidArguments(
        "unable to write \(label) lock owner: \(lockURL.path) errno=\(errno)"
      )
    }
  }
}
