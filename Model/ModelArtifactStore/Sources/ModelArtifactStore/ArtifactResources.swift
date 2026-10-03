import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

public final class ArtifactStaging: @unchecked Sendable {
  public let directoryURL: URL
  public let manifest: ArtifactManifest
  internal let identifier: String
  internal let lock: ArtifactFileLock
  internal let directoryDescriptor: Int32
  private let mutex = NSLock()
  private var consumed = false

  internal init(
    directoryURL: URL, manifest: ArtifactManifest, identifier: String,
    lock: ArtifactFileLock, directoryDescriptor: Int32
  ) {
    self.directoryURL = directoryURL
    self.manifest = manifest
    self.identifier = identifier
    self.lock = lock
    self.directoryDescriptor = directoryDescriptor
  }

  internal func consume() throws -> Int32 {
    mutex.lock()
    defer { mutex.unlock() }
    guard !consumed else { throw ArtifactStoreError.consumedStaging }
    consumed = true
    lock.close()
    let copy = dup(directoryDescriptor)
    guard copy >= 0 else { throw ArtifactStoreError.storageFailure }
    return copy
  }

  public func importFiles(from sourceDirectoryURL: URL) throws {
    mutex.lock()
    defer { mutex.unlock() }
    guard !consumed, sourceDirectoryURL.isFileURL else {
      throw ArtifactStoreError.consumedStaging
    }
    let source = try nativeAgentOpenDirectory(path: sourceDirectoryURL.standardizedFileURL.path)
    defer { nativeAgentClose(source) }
    for entry in manifest.files {
      try Task.checkCancellation()
      try nativeAgentCopyRegularFile(
        sourceRoot: source, destinationRoot: directoryDescriptor, entry: entry)
    }
  }

  public func abandon() {
    mutex.lock()
    defer { mutex.unlock() }
    guard !consumed else { return }
    consumed = true
    lock.close()
    _ = ".native-agent-stage.lock".withCString { unlinkat(directoryDescriptor, $0, 0) }
  }

  deinit {
    lock.close()
    nativeAgentClose(directoryDescriptor)
  }
}

public final class ArtifactLease: @unchecked Sendable {
  public let directoryURL: URL
  public let manifest: ArtifactManifest
  private let lock: ArtifactFileLock
  private let directoryHandle: FileHandle

  internal init(
    directoryURL: URL, manifest: ArtifactManifest, lock: ArtifactFileLock, descriptor: Int32
  ) {
    self.directoryURL = directoryURL
    self.manifest = manifest
    self.lock = lock
    directoryHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  public func close() {
    lock.close()
    try? directoryHandle.close()
  }
}
