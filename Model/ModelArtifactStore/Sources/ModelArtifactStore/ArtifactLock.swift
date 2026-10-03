import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif


private enum ArtifactStoreInternalLimits {
  static let maximumScannedEntries = 1_000_000
  static let maximumScannedEntriesPerExpectedFile = 32
  static let copyBufferBytes = 1 * 1_024 * 1_024
}

func nativeAgentClose(_ descriptor: Int32) {
  #if canImport(Darwin)
    _ = Darwin.close(descriptor)
  #else
    _ = Glibc.close(descriptor)
  #endif
}

func nativeAgentOpenDirectory(path: String) throws -> Int32 {
  let descriptor = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
  guard descriptor >= 0 else { throw ArtifactStoreError.unsupportedEntry }
  return descriptor
}

func nativeAgentOpenDirectory(parent: Int32, name: String, create: Bool = false) throws -> Int32 {
  if create {
    let result = name.withCString { mkdirat(parent, $0, S_IRWXU) }
    guard result == 0 || errno == EEXIST else { throw ArtifactStoreError.storageFailure }
  }
  let descriptor = name.withCString {
    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  }
  guard descriptor >= 0 else { throw ArtifactStoreError.unsupportedEntry }
  return descriptor
}

func nativeAgentOpenOptionalDirectory(parent: Int32, name: String) throws -> Int32? {
  let descriptor = name.withCString {
    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  }
  if descriptor >= 0 { return descriptor }
  if errno == ENOENT { return nil }
  throw ArtifactStoreError.unsupportedEntry
}

final class ArtifactFileLock: @unchecked Sendable {
  private let handle: FileHandle
  private let mutex = NSLock()
  private var closed = false

  init(directory: Int32, name: String, exclusive: Bool, nonblocking: Bool) throws {
    let descriptor = name.withCString {
      openat(directory, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { throw ArtifactStoreError.storageFailure }
    var information = stat()
    guard fstat(descriptor, &information) == 0,
      information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), information.st_nlink == 1
    else {
      nativeAgentClose(descriptor)
      throw ArtifactStoreError.unsupportedEntry
    }
    var operation = exclusive ? LOCK_EX : LOCK_SH
    if nonblocking { operation |= LOCK_NB }
    guard flock(descriptor, operation) == 0 else {
      let code = errno
      nativeAgentClose(descriptor)
      if code == EWOULDBLOCK { throw ArtifactStoreError.busy }
      throw ArtifactStoreError.storageFailure
    }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  /// Retains the same open-file-description lock while making a just-published
  /// snapshot readable by concurrent leases.  There is no unlocked window
  /// between publication and lease ownership.
  func downgradeToShared() throws {
    mutex.lock()
    defer { mutex.unlock() }
    guard !closed else { throw ArtifactStoreError.storageFailure }
    guard flock(handle.fileDescriptor, LOCK_SH) == 0 else {
      throw ArtifactStoreError.storageFailure
    }
  }

  func close() {
    mutex.lock()
    defer { mutex.unlock() }
    guard !closed else { return }
    _ = flock(handle.fileDescriptor, LOCK_UN)
    try? handle.close()
    closed = true
  }

  deinit { close() }
}

struct ArtifactScannedFile: Equatable {
  let byteCount: UInt64
  let digest: ArtifactDigest
}

func nativeAgentScanTree(
  directory: Int32, prefix: String = "", expected: [String: ArtifactEntry],
  expectedDirectoryPrefixes: Set<String>, visitedEntries: inout Int, checkingCancellation: Bool
) throws -> [String: ArtifactScannedFile] {
  let duplicate = dup(directory)
  guard duplicate >= 0, let stream = fdopendir(duplicate) else {
    if duplicate >= 0 { nativeAgentClose(duplicate) }
    throw ArtifactStoreError.storageFailure
  }
  defer { closedir(stream) }
  var files: [String: ArtifactScannedFile] = [:]
  errno = 0
  while let entry = readdir(stream) {
    let name = withUnsafePointer(to: &entry.pointee.d_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
    }
    if name == "." || name == ".." { continue }
    visitedEntries += 1
    guard visitedEntries <= min(ArtifactStoreInternalLimits.maximumScannedEntries, expected.count * ArtifactStoreInternalLimits.maximumScannedEntriesPerExpectedFile) else {
      throw ArtifactStoreError.limitExceeded
    }
    var information = stat()
    guard name.withCString({ fstatat(directory, $0, &information, AT_SYMLINK_NOFOLLOW) }) == 0
    else {
      throw ArtifactStoreError.storageFailure
    }
    let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
    try ArtifactManifest.validate(path: path)
    let kind = information.st_mode & mode_t(S_IFMT)
    if kind == mode_t(S_IFDIR) {
      guard expectedDirectoryPrefixes.contains(path) else {
        throw ArtifactStoreError.missingFile
      }
      let child = try nativeAgentOpenDirectory(parent: directory, name: name)
      let nested: [String: ArtifactScannedFile]
      do {
        nested = try nativeAgentScanTree(
          directory: child, prefix: path, expected: expected,
          expectedDirectoryPrefixes: expectedDirectoryPrefixes, visitedEntries: &visitedEntries,
          checkingCancellation: checkingCancellation)
      } catch {
        nativeAgentClose(child)
        throw error
      }
      nativeAgentClose(child)
      for (key, value) in nested {
        guard files.updateValue(value, forKey: key) == nil else {
          throw ArtifactStoreError.invalidManifest
        }
      }
    } else if kind == mode_t(S_IFREG) {
      guard information.st_nlink == 1, information.st_size >= 0 else {
        throw ArtifactStoreError.unsupportedEntry
      }
      guard let expectedFile = expected[path] else { throw ArtifactStoreError.missingFile }
      guard UInt64(information.st_size) == expectedFile.byteCount else {
        throw ArtifactStoreError.sizeMismatch
      }
      let descriptor = name.withCString { openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
      guard descriptor >= 0 else { throw ArtifactStoreError.unsupportedEntry }
      var opened = stat()
      guard fstat(descriptor, &opened) == 0, opened.st_dev == information.st_dev,
        opened.st_ino == information.st_ino, opened.st_size == information.st_size
      else {
        nativeAgentClose(descriptor)
        throw ArtifactStoreError.storageFailure
      }
      var hasher = SHA256()
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      do {
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
          if checkingCancellation { try Task.checkCancellation() }
          hasher.update(data: data)
        }
      } catch {
        nativeAgentClose(descriptor)
        throw error
      }
      nativeAgentClose(descriptor)
      let digest = ArtifactDigest(
        rawValue: hasher.finalize().map { String(format: "%02x", $0) }.joined())!
      guard digest == expectedFile.sha256 else { throw ArtifactStoreError.digestMismatch }
      guard
        files.updateValue(.init(byteCount: UInt64(opened.st_size), digest: digest), forKey: path)
          == nil
      else { throw ArtifactStoreError.invalidManifest }
    } else {
      throw ArtifactStoreError.unsupportedEntry
    }
    errno = 0
  }
  guard errno == 0 else { throw ArtifactStoreError.storageFailure }
  return files
}

func nativeAgentRemoveTree(parent: Int32, name: String) throws {
  let directory = try nativeAgentOpenDirectory(parent: parent, name: name)
  let duplicate = dup(directory)
  guard duplicate >= 0, let stream = fdopendir(duplicate) else {
    nativeAgentClose(directory)
    if duplicate >= 0 { nativeAgentClose(duplicate) }
    throw ArtifactStoreError.storageFailure
  }
  var failure: (any Error)?
  errno = 0
  while failure == nil, let entry = readdir(stream) {
    let childName = withUnsafePointer(to: &entry.pointee.d_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
    }
    if childName == "." || childName == ".." { continue }
    var info = stat()
    guard childName.withCString({ fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
      failure = ArtifactStoreError.storageFailure
      break
    }
    do {
      if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
        try nativeAgentRemoveTree(parent: directory, name: childName)
      } else if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
        guard childName.withCString({ unlinkat(directory, $0, 0) }) == 0 else {
          throw ArtifactStoreError.storageFailure
        }
      } else {
        throw ArtifactStoreError.unsupportedEntry
      }
    } catch { failure = error }
    errno = 0
  }
  if errno != 0, failure == nil { failure = ArtifactStoreError.storageFailure }
  closedir(stream)
  nativeAgentClose(directory)
  if let failure { throw failure }
  guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
    throw ArtifactStoreError.storageFailure
  }
}

func nativeAgentCopyRegularFile(
  sourceRoot: Int32, destinationRoot: Int32, entry: ArtifactEntry
) throws {
  try ArtifactManifest.validate(path: entry.path)
  let components = entry.path.split(separator: "/").map(String.init)
  guard let fileName = components.last else { throw ArtifactStoreError.invalidPath }

  var sourceParent = dup(sourceRoot)
  var destinationParent = dup(destinationRoot)
  guard sourceParent >= 0, destinationParent >= 0 else {
    if sourceParent >= 0 { nativeAgentClose(sourceParent) }
    if destinationParent >= 0 { nativeAgentClose(destinationParent) }
    throw ArtifactStoreError.storageFailure
  }
  defer {
    nativeAgentClose(sourceParent)
    nativeAgentClose(destinationParent)
  }
  for component in components.dropLast() {
    let nextSource = try nativeAgentOpenDirectory(parent: sourceParent, name: component)
    let nextDestination: Int32
    do {
      nextDestination = try nativeAgentOpenDirectory(
        parent: destinationParent, name: component, create: true)
    } catch {
      nativeAgentClose(nextSource)
      throw error
    }
    nativeAgentClose(sourceParent)
    nativeAgentClose(destinationParent)
    sourceParent = nextSource
    destinationParent = nextDestination
  }

  let source = fileName.withCString {
    openat(sourceParent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
  }
  guard source >= 0 else { throw ArtifactStoreError.unsupportedEntry }
  defer { nativeAgentClose(source) }
  var sourceInfo = stat()
  guard fstat(source, &sourceInfo) == 0,
    sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), sourceInfo.st_size >= 0,
    UInt64(sourceInfo.st_size) == entry.byteCount
  else { throw ArtifactStoreError.sizeMismatch }

  let destination = fileName.withCString {
    openat(
      destinationParent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR)
  }
  guard destination >= 0 else { throw ArtifactStoreError.storageFailure }
  var keepDestination = false
  defer {
    nativeAgentClose(destination)
    if !keepDestination { _ = fileName.withCString { unlinkat(destinationParent, $0, 0) } }
  }

  var copied: UInt64 = 0
  var buffer = [UInt8](repeating: 0, count: ArtifactStoreInternalLimits.copyBufferBytes)
  while true {
    try Task.checkCancellation()
    let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
    if count < 0 {
      if errno == EINTR { continue }
      throw ArtifactStoreError.storageFailure
    }
    if count == 0 { break }
    let (next, overflow) = copied.addingReportingOverflow(UInt64(count))
    guard !overflow, next <= entry.byteCount else { throw ArtifactStoreError.sizeMismatch }
    copied = next
    var offset = 0
    while offset < count {
      let written = buffer.withUnsafeBytes {
        write(destination, $0.baseAddress?.advanced(by: offset), count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        throw ArtifactStoreError.storageFailure
      }
      guard written > 0 else { throw ArtifactStoreError.storageFailure }
      offset += written
    }
  }
  guard copied == entry.byteCount else { throw ArtifactStoreError.sizeMismatch }
  guard fsync(destination) == 0 else { throw ArtifactStoreError.storageFailure }
  keepDestination = true
}
