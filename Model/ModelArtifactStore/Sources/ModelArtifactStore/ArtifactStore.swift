import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

public actor ModelArtifactStore {
  public static let standardMinimumFreeBytes: UInt64 = 128 * 1_024 * 1_024

  private let root: URL
  private let minimumFreeBytes: UInt64
  private let availableBytes: @Sendable (URL) throws -> UInt64
  private let verificationObserver: @Sendable () -> Void
  private let stagingDescriptor: Int32
  private let artifactsDescriptor: Int32
  private let locksDescriptor: Int32

  public init(rootURL: URL, minimumFreeBytes: UInt64 = ModelArtifactStore.standardMinimumFreeBytes) throws {
    try self.init(
      rootURL: rootURL, minimumFreeBytes: minimumFreeBytes,
      availableBytes: { url in
      let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      guard let value = values.volumeAvailableCapacityForImportantUsage, value >= 0 else {
        throw ArtifactStoreError.storageFailure
      }
      return UInt64(value)
      }, verificationObserver: {})
  }

  init(
    rootURL: URL, minimumFreeBytes: UInt64,
    availableBytes: @escaping @Sendable (URL) throws -> UInt64,
    verificationObserver: @escaping @Sendable () -> Void = {}
  ) throws {
    guard rootURL.isFileURL, minimumFreeBytes <= UInt64(Int64.max) else {
      throw ArtifactStoreError.storageFailure
    }
    root = rootURL.standardizedFileURL
    self.minimumFreeBytes = minimumFreeBytes
    self.availableBytes = availableBytes
    self.verificationObserver = verificationObserver
    if !FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let rootDescriptor = try nativeAgentOpenDirectory(path: root.path)
    var openedStaging: Int32 = -1
    var openedArtifacts: Int32 = -1
    var openedLocks: Int32 = -1
    do {
      openedStaging = try nativeAgentOpenDirectory(
        parent: rootDescriptor, name: "staging", create: true)
      openedArtifacts = try nativeAgentOpenDirectory(
        parent: rootDescriptor, name: "artifacts", create: true)
      openedLocks = try nativeAgentOpenDirectory(parent: rootDescriptor, name: "locks", create: true)
      nativeAgentClose(rootDescriptor)
    } catch {
      if openedArtifacts >= 0 { nativeAgentClose(openedArtifacts) }
      if openedStaging >= 0 { nativeAgentClose(openedStaging) }
      nativeAgentClose(rootDescriptor)
      throw error
    }
    stagingDescriptor = openedStaging
    artifactsDescriptor = openedArtifacts
    locksDescriptor = openedLocks
  }

  deinit {
    nativeAgentClose(stagingDescriptor)
    nativeAgentClose(artifactsDescriptor)
    nativeAgentClose(locksDescriptor)
  }

  public func beginStaging(for manifest: ArtifactManifest) throws -> ArtifactStaging {
    try manifest.validate()
    let (required, overflow) = manifest.totalBytes.addingReportingOverflow(minimumFreeBytes)
    guard !overflow, try availableBytes(root) >= required else {
      throw ArtifactStoreError.limitExceeded
    }
    let identifier = UUID().uuidString.lowercased()
    let descriptor = try nativeAgentOpenDirectory(parent: stagingDescriptor, name: identifier, create: true)
    do {
      let lock = try ArtifactFileLock(
        directory: descriptor, name: ".native-agent-stage.lock", exclusive: true, nonblocking: true)
      return ArtifactStaging(
        directoryURL: root.appending(path: "staging/\(identifier)", directoryHint: .isDirectory),
        manifest: manifest, identifier: identifier, lock: lock, directoryDescriptor: descriptor)
    } catch {
      nativeAgentClose(descriptor)
      throw error
    }
  }

  /// Publishes a verified staging transaction and transfers its artifact lock
  /// directly into a shared lease. The staging tree is hashed once before its
  /// atomic rename; the same immutable snapshot then becomes the lease root,
  /// so a large newly published artifact is never re-hashed merely to open it.
  public func publish(_ staging: ArtifactStaging) async throws -> ArtifactLease {
    try staging.manifest.validate()
    try Task.checkCancellation()
    let coordination = try await acquireLock(name: "staging.lock", exclusive: true)
    defer { coordination.close() }
    try Task.checkCancellation()
    let stage = try staging.consume()
    defer { nativeAgentClose(stage) }
    let quarantine = "verify-\(UUID().uuidString.lowercased())"
    try Task.checkCancellation()
    guard
      staging.identifier.withCString({ oldName in
        quarantine.withCString { newName in
          renameat(stagingDescriptor, oldName, stagingDescriptor, newName)
        }
      }) == 0
    else { throw ArtifactStoreError.storageFailure }
    _ = ".native-agent-stage.lock".withCString { unlinkat(stage, $0, 0) }
    let artifactParent = try nativeAgentOpenDirectory(
      parent: artifactsDescriptor, name: staging.manifest.artifactID, create: true)
    defer { nativeAgentClose(artifactParent) }
    var artifactLock: ArtifactFileLock? = try await acquireLock(
      name: lockName(for: staging.manifest), exclusive: true)
    defer { artifactLock?.close() }
    try Task.checkCancellation()
    let digest = staging.manifest.manifestDigest.rawValue
    if let existing = try nativeAgentOpenOptionalDirectory(parent: artifactParent, name: digest) {
      do {
        try verify(directory: existing, manifest: staging.manifest)
        try nativeAgentRemoveTree(parent: stagingDescriptor, name: quarantine)
        try artifactLock!.downgradeToShared()
        let lock = artifactLock!
        artifactLock = nil
        return ArtifactLease(
          directoryURL: artifactURL(for: staging.manifest), manifest: staging.manifest,
          lock: lock, descriptor: existing)
      } catch is CancellationError {
        nativeAgentClose(existing)
        throw CancellationError()
      } catch let error as ArtifactStoreError {
        nativeAgentClose(existing)
        switch error {
        case .invalidManifest, .invalidPath, .unsupportedEntry, .limitExceeded,
          .sizeMismatch, .digestMismatch, .missingFile:
          try nativeAgentRemoveTree(parent: artifactParent, name: digest)
        case .busy, .consumedStaging, .storageFailure:
          throw error
        }
      } catch {
        nativeAgentClose(existing)
        throw error
      }
    }
    try verify(directory: stage, manifest: staging.manifest)
    try Task.checkCancellation()
    guard
      quarantine.withCString({ oldName in
        digest.withCString { newName in
          renameat(stagingDescriptor, oldName, artifactParent, newName)
        }
      }) == 0
    else { throw ArtifactStoreError.storageFailure }
    let published = try nativeAgentOpenDirectory(parent: artifactParent, name: digest)
    do {
      try artifactLock!.downgradeToShared()
      let lock = artifactLock!
      artifactLock = nil
      return ArtifactLease(
        directoryURL: artifactURL(for: staging.manifest), manifest: staging.manifest,
        lock: lock, descriptor: published)
    } catch {
      nativeAgentClose(published)
      do { try nativeAgentRemoveTree(parent: artifactParent, name: digest) } catch {
        throw ArtifactStoreError.storageFailure
      }
      throw error
    }
  }

  public func open(_ manifest: ArtifactManifest) async throws -> ArtifactLease {
    try manifest.validate()
    let lock = try await acquireLock(name: lockName(for: manifest), exclusive: false)
    do {
      guard
        let parent = try nativeAgentOpenOptionalDirectory(
          parent: artifactsDescriptor, name: manifest.artifactID)
      else { throw ArtifactStoreError.missingFile }
      defer { nativeAgentClose(parent) }
      guard
        let snapshot = try nativeAgentOpenOptionalDirectory(
          parent: parent, name: manifest.manifestDigest.rawValue)
      else { throw ArtifactStoreError.missingFile }
      do { try verify(directory: snapshot, manifest: manifest) } catch {
        nativeAgentClose(snapshot)
        throw error
      }
      return ArtifactLease(
        directoryURL: artifactURL(for: manifest),
        manifest: manifest, lock: lock, descriptor: snapshot)
    } catch {
      lock.close()
      throw error
    }
  }

  public func remove(_ manifest: ArtifactManifest) throws {
    try manifest.validate()
    let lock = try ArtifactFileLock(
      directory: locksDescriptor, name: lockName(for: manifest), exclusive: true, nonblocking: true)
    defer { lock.close() }
    let parent = try nativeAgentOpenDirectory(parent: artifactsDescriptor, name: manifest.artifactID)
    defer { nativeAgentClose(parent) }
    do {
      try nativeAgentRemoveTree(parent: parent, name: manifest.manifestDigest.rawValue)
    } catch ArtifactStoreError.unsupportedEntry { throw ArtifactStoreError.missingFile }
  }

  public func recoverStaging(olderThan age: Duration) async throws -> Int {
    guard age >= .zero else { throw ArtifactStoreError.invalidManifest }
    let coordination = try await acquireLock(name: "staging.lock", exclusive: true)
    defer { coordination.close() }
    try Task.checkCancellation()
    let threshold = Int64(
      Date().addingTimeInterval(-age.timeInterval).timeIntervalSince1970.rounded(.down))
    var removed = 0
    for name in try listDirectories(stagingDescriptor) {
      var info = stat()
      guard name.withCString({ fstatat(stagingDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
      else { throw ArtifactStoreError.unsupportedEntry }
      guard info.st_mtimespec.tv_sec < threshold else { continue }
      let directory = try nativeAgentOpenDirectory(parent: stagingDescriptor, name: name)
      do {
        let lock = try ArtifactFileLock(
          directory: directory, name: ".native-agent-stage.lock", exclusive: true, nonblocking: true)
        lock.close()
        nativeAgentClose(directory)
        try nativeAgentRemoveTree(parent: stagingDescriptor, name: name)
        removed += 1
      } catch ArtifactStoreError.busy {
        nativeAgentClose(directory)
        continue
      } catch {
        nativeAgentClose(directory)
        throw error
      }
    }
    return removed
  }

  private func acquireLock(name: String, exclusive: Bool) async throws -> ArtifactFileLock {
    while true {
      try Task.checkCancellation()
      do {
        return try ArtifactFileLock(
          directory: locksDescriptor, name: name, exclusive: exclusive, nonblocking: true)
      } catch ArtifactStoreError.busy {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
  }

  private func lockName(for manifest: ArtifactManifest) -> String {
    "\(manifest.artifactID)-\(manifest.manifestDigest.rawValue).lock"
  }

  private func artifactURL(for manifest: ArtifactManifest) -> URL {
    root.appending(
      path: "artifacts/\(manifest.artifactID)/\(manifest.manifestDigest.rawValue)",
      directoryHint: .isDirectory)
  }

  private func verify(directory: Int32, manifest: ArtifactManifest) throws {
    verificationObserver()
    try Self.verify(directory: directory, manifest: manifest)
  }

  private static func verify(
    directory: Int32, manifest: ArtifactManifest, checkingCancellation: Bool = true
  ) throws {
    let expected = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
    var expectedDirectoryPrefixes: Set<String> = []
    for entry in manifest.files {
      var components = entry.path.split(separator: "/").map(String.init)
      _ = components.popLast()
      var prefix = ""
      for component in components {
        prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
        expectedDirectoryPrefixes.insert(prefix)
      }
    }
    var visitedEntries = 0
    let actual = try nativeAgentScanTree(
      directory: directory, expected: expected,
      expectedDirectoryPrefixes: expectedDirectoryPrefixes, visitedEntries: &visitedEntries,
      checkingCancellation: checkingCancellation)
    guard actual.count == manifest.files.count,
      manifest.files.allSatisfy({ actual[$0.path] != nil })
    else { throw ArtifactStoreError.missingFile }
    for expected in manifest.files {
      guard let file = actual[expected.path] else { throw ArtifactStoreError.missingFile }
      guard file.byteCount == expected.byteCount else { throw ArtifactStoreError.sizeMismatch }
      guard file.digest == expected.sha256 else { throw ArtifactStoreError.digestMismatch }
    }
  }

  private func listDirectories(_ descriptor: Int32) throws -> [String] {
    let iteratorDescriptor = try nativeAgentOpenDirectory(parent: descriptor, name: ".")
    guard let stream = fdopendir(iteratorDescriptor) else {
      nativeAgentClose(iteratorDescriptor)
      throw ArtifactStoreError.storageFailure
    }
    defer { closedir(stream) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name != "." && name != ".." { names.append(name) }
      errno = 0
    }
    guard errno == 0 else { throw ArtifactStoreError.storageFailure }
    return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
