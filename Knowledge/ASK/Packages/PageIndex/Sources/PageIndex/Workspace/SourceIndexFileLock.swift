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
    defer { close(descriptor) }

    guard flock(descriptor, LOCK_SH) == 0 else {
      throw ASKPageIndexError.invalidArguments(
        "unable to acquire \(label) shared lock: \(lockURL.path) errno=\(errno)"
      )
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
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
    defer { close(descriptor) }

    guard flock(descriptor, LOCK_EX) == 0 else {
      throw ASKPageIndexError.invalidArguments(
        "unable to acquire \(label) lock: \(lockURL.path) errno=\(errno)"
      )
    }
    defer { _ = flock(descriptor, LOCK_UN) }

    try writeOwner(descriptor: descriptor, label: label, lockURL: lockURL)
    defer { _ = ftruncate(descriptor, 0) }

    return try body()
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
