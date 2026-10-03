import Foundation

/// Filesystem adapter for the source index. All mutation is protected by a cross-process lock.
struct SourceIndexWorkspace {
  static let manifestFileName = "_source_manifest.json"

  /// Deterministic artifact filenames are pure functions of the sourceID, but
  /// each one costs a SHA-256 over the ID. Manifest loads validate every entry
  /// against this name, so a batch import would otherwise hash all previous
  /// IDs on every put (O(n²) hashing). The memo is process-lifetime and grows
  /// only with distinct sourceIDs.
  private static let fileNameCacheLock = NSLock()
  private nonisolated(unsafe) static var fileNameCache: [SourceID: String] = [:]

  private static func sourceDigest(for sourceID: SourceID) -> String {
    StableDigest.sha256Hex(Data(sourceID.rawValue.utf8))
  }

  static func artifactFileName(for sourceID: SourceID) -> String {
    fileNameCacheLock.lock()
    if let cached = fileNameCache[sourceID] {
      fileNameCacheLock.unlock()
      return cached
    }
    fileNameCacheLock.unlock()

    let digest = sourceDigest(for: sourceID)
    let value = "src_\(digest).json"

    fileNameCacheLock.lock()
    fileNameCache[sourceID] = value
    fileNameCacheLock.unlock()
    return value
  }

  private let workspaceURL: URL
  private let artifactsDirectoryURL: URL
  private let historyDirectoryURL: URL
  private let backlinksDirectoryURL: URL
  private let lockURL: URL

  init(workspaceURL: URL) throws {
    let canonicalURL = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    self.workspaceURL = canonicalURL
    self.artifactsDirectoryURL = canonicalURL.appendingPathComponent(
      "artifacts",
      isDirectory: true
    )
    self.historyDirectoryURL = canonicalURL.appendingPathComponent(
      "history",
      isDirectory: true
    )
    self.backlinksDirectoryURL = canonicalURL.appendingPathComponent(
      "backlinks",
      isDirectory: true
    )
    self.lockURL = canonicalURL.appendingPathComponent(".source-index.lock")

    // Opening an existing workspace must fail immediately if its manifest is corrupt,
    // while opening a missing workspace remains side-effect free.
    _ = try loadManifest()
  }

  func list() throws -> [SourceIndexManifestEntry] {
    try withReadLock {
      try loadManifest().values.sorted { lhs, rhs in
        lhs.sourceID.rawValue < rhs.sourceID.rawValue
      }
    }
  }

  func revisionToken() throws -> SourceIndexRevisionToken? {
    try withReadLock {
      let manifestURL = workspaceURL.appendingPathComponent(Self.manifestFileName)
      guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
      let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
      guard let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
      let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
      return SourceIndexRevisionToken(modificationDate: modifiedAt, size: size)
    }
  }

  func snapshot() throws -> [SourceIndexArtifact] {
    try withReadLock {
      let entries = try loadManifest().values.sorted { lhs, rhs in
        lhs.sourceID.rawValue < rhs.sourceID.rawValue
      }
      return try entries.map { entry in
        let url = artifactURL(for: entry.sourceID)
        let artifact: SourceIndexArtifact
        do {
          artifact = try Self.readJSON(SourceIndexArtifact.self, from: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
          throw ASKPageIndexError.fileNotFound(url.path)
        }
        try Self.validate(artifact: artifact, against: entry)
        return artifact
      }
    }
  }

  func put(_ artifact: SourceIndexArtifact) throws -> SourceIndexManifestEntry {
    let entries = try put([artifact])
    guard let entry = entries.first else {
      throw ASKPageIndexError.invalidArguments("source index put returned no entry")
    }
    return entry
  }

  /// Writes many artifacts under one lock with a persisted before-state.
  /// Interrupted publication blocks reads until explicit or next-write recovery.
  func put(
    _ artifacts: [SourceIndexArtifact],
    sourceRootURL: URL? = nil,
    discoveredSourceURLs: [URL] = []
  ) throws -> [SourceIndexManifestEntry] {
    guard !artifacts.isEmpty || sourceRootURL != nil else { return [] }
    let rootIdentity = sourceRootURL.map(SourceIdentityFactory.rootIdentity(for:))
    let discoveredIDs = Set(discoveredSourceURLs.map(SourceIdentityFactory.makeID(forFileAt:)))
    if let rootIdentity {
      guard discoveredSourceURLs.allSatisfy({ SourceIdentityFactory.contains(fileAt: $0, rootIdentity: rootIdentity) }),
            artifacts.allSatisfy({ artifact in
              guard let path = artifact.sourcePath else { return false }
              let url = URL(fileURLWithPath: path)
              return SourceIdentityFactory.contains(fileAt: url, rootIdentity: rootIdentity)
                && SourceIdentityFactory.makeID(forFileAt: url) == artifact.document.sourceID
                && discoveredIDs.contains(artifact.document.sourceID)
            }) else {
        throw ASKPageIndexError.invalidArguments("source reconciliation contains an artifact outside its discovered root")
      }
    }
    let sourceIDs = artifacts.map { $0.document.sourceID.rawValue }
    guard Set(sourceIDs).count == sourceIDs.count else {
      throw ASKPageIndexError.invalidArguments("source index batch contains duplicate source IDs")
    }
    for artifact in artifacts {
      try SourceIndexArtifactValidator.validate(artifact)
    }
    return try withWriteLock {
      var manifest = try loadManifest()

      struct PlannedWrite {
        let entry: SourceIndexManifestEntry
        let data: Data?
        let artifactURL: URL
        let historyURL: URL?
        let historicalData: Data?
        let historicalPreviousData: Data?
      }

      var planned: [PlannedWrite] = []
      planned.reserveCapacity(artifacts.count)

      do {
        for artifact in artifacts {
          if let rootIdentity, let owner = manifest[artifact.document.sourceID.rawValue]?.sourceRootIdentity,
             owner != rootIdentity {
            throw ASKPageIndexError.invalidArguments("source is already owned by a different indexing root")
          }
          let artifactURL = self.artifactURL(for: artifact.document.sourceID)
          let previousArtifact = try Self.readDataIfPresent(at: artifactURL)
          let historicalArtifact = try previousArtifact.flatMap { try Self.decodeArtifact(from: $0) }
          if let historicalArtifact {
            try SourceIndexArtifactValidator.validate(historicalArtifact)
          }
          let historyURL = historicalArtifact.flatMap { previous in
            previous.version.checksum == artifact.version.checksum
              ? nil
              : historicalArtifactURL(for: artifact.document.sourceID, version: previous.version)
          }
          let previousHistory = try historyURL.flatMap(Self.readDataIfPresent(at:))
          let entry = SourceIndexManifestEntry(
            sourceID: artifact.document.sourceID,
            artifactFileName: Self.artifactFileName(for: artifact.document.sourceID),
            type: artifact.document.type,
            title: artifact.document.title,
            version: artifact.version,
            sourcePath: artifact.sourcePath,
            sourceRootIdentity: rootIdentity ?? manifest[artifact.document.sourceID.rawValue]?.sourceRootIdentity
          )
          let data = try Self.makeEncoder().encode(artifact)
          let historicalData: Data? = try {
            guard let historical = historicalArtifact, historyURL != nil else { return nil }
            return try Self.makeEncoder().encode(historical)
          }()
          if let previousHistory, let historicalData {
            guard try Self.sameIndexedContent(previousHistory, historicalData) else {
              throw ASKPageIndexError.invalidArguments(
                "source index history conflict for \(artifact.document.sourceID.rawValue) version \(historicalArtifact?.version.checksum ?? "?")"
              )
            }
          }
          planned.append(PlannedWrite(
            entry: entry,
            data: data,
            artifactURL: artifactURL,
            historyURL: historyURL,
            historicalData: historicalData,
            historicalPreviousData: previousHistory
          ))
        }
        if let rootIdentity {
          for entry in manifest.values.sorted(by: { $0.sourceID.rawValue < $1.sourceID.rawValue }) {
            let belongs = entry.sourceRootIdentity == rootIdentity
            guard belongs, !discoveredIDs.contains(entry.sourceID) else { continue }
            let url = artifactURL(for: entry.sourceID)
            let previous = try Data(contentsOf: url)
            let artifact = try Self.decodeArtifact(from: previous)
            try Self.validate(artifact: artifact, against: entry)
            let historyURL = historicalArtifactURL(for: entry.sourceID, version: artifact.version)
            let historicalData = try Self.makeEncoder().encode(artifact)
            let priorHistory = try Self.readDataIfPresent(at: historyURL)
            if let priorHistory, try Self.sameIndexedContent(priorHistory, historicalData) == false {
              throw ASKPageIndexError.invalidArguments("source index history conflict while retiring \(entry.sourceID.rawValue)")
            }
            planned.append(PlannedWrite(entry: entry, data: nil,
              artifactURL: url, historyURL: historyURL, historicalData: historicalData,
              historicalPreviousData: priorHistory))
          }
        }
        try FileManager.default.createDirectory(
          at: artifactsDirectoryURL,
          withIntermediateDirectories: true
        )
      } catch {
        throw ASKPageIndexError.invalidArguments(
          "source index batch put planning failed: \(error)")
      }

      var writes: [SourceIndexTransaction.Write] = []
      for write in planned {
        if let historyURL = write.historyURL, let historicalData = write.historicalData,
           write.historicalPreviousData == nil {
          let sourceDirectory = StableDigest.sha256Hex(Data(write.entry.sourceID.rawValue.utf8))
          writes.append(.init(
            relativePath: "history/\(sourceDirectory)/\(historyURL.lastPathComponent)",
            data: historicalData
          ))
        }
        writes.append(.init(
          relativePath: "artifacts/\(write.entry.artifactFileName)",
          data: write.data
        ))
        if write.data != nil { manifest[write.entry.sourceID.rawValue] = write.entry }
        else { manifest.removeValue(forKey: write.entry.sourceID.rawValue) }
      }
      writes.append(.init(
        relativePath: Self.manifestFileName,
        data: try Self.makeEncoder().encode(manifest)
      ))
      try SourceIndexTransaction(root: workspaceURL).publish(writes)

      return planned.filter { $0.data != nil }.map(\.entry)
    }
  }

  func get(sourceID: SourceID) throws -> SourceIndexArtifact? {
    try withReadLock {
    let manifest = try loadManifest()
    guard let entry = manifest[sourceID.rawValue] else { return nil }

    let url = artifactURL(for: sourceID)
    let artifact: SourceIndexArtifact
    do {
      artifact = try Self.readJSON(SourceIndexArtifact.self, from: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      throw ASKPageIndexError.fileNotFound(url.path)
      }
    try Self.validate(artifact: artifact, against: entry)
    return artifact
    }
  }

  func history(sourceID: SourceID) throws -> [SourceIndexArtifact] {
    try withReadLock {
    let directory = historicalDirectoryURL(for: sourceID)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    return try urls
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { url in
        let artifact = try Self.readJSON(SourceIndexArtifact.self, from: url)
        try SourceIndexArtifactValidator.validate(artifact)
        guard artifact.document.sourceID == sourceID else {
          throw ASKPageIndexError.invalidArguments("source index history source ID mismatch")
    }
        guard url.lastPathComponent == Self.historicalArtifactFileName(for: artifact.version) else {
          throw ASKPageIndexError.invalidArguments("source index history contains non-canonical artifact path")
  }
        return artifact
        }
    }
  }

  func delete(sourceID: SourceID) throws {
    try withWriteLock {
      var manifest = try loadManifest()
      manifest.removeValue(forKey: sourceID.rawValue)
      var writes = [SourceIndexTransaction.Write(
        relativePath: "artifacts/\(Self.artifactFileName(for: sourceID))",
        data: nil
      )]
      let directory = historicalDirectoryURL(for: sourceID)
      if FileManager.default.fileExists(atPath: directory.path) {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .sorted(by: { $0.path < $1.path }) {
          writes.append(.init(
            relativePath: "history/\(directory.lastPathComponent)/\(url.lastPathComponent)",
            data: nil
          ))
        }
      }
      writes.append(.init(
        relativePath: Self.manifestFileName,
        data: try Self.makeEncoder().encode(manifest)
      ))
      try SourceIndexTransaction(root: workspaceURL).publish(writes)
    }
  }

  /// Does not create an absent index. A corrupt recovery record is never ignored.
  func recoverPendingWrite() throws -> Bool {
    guard FileManager.default.fileExists(atPath: workspaceURL.path) else { return false }
    return try SourceIndexFileLock.withExclusiveLock(at: lockURL, label: "source index") {
      try SourceIndexTransaction(root: workspaceURL).recover()
    }
  }

  /// Conservative retention authority: every retained indexed version pins its
  /// source bytes, even after it leaves active membership. History is not a cache.
  func retainedSourcePaths() throws -> [String] {
    try withReadLock {
      var paths = Set<String>()
      for entry in try loadManifest().values {
        let artifact = try Self.readJSON(SourceIndexArtifact.self, from: artifactURL(for: entry.sourceID))
        try Self.validate(artifact: artifact, against: entry)
        if let path = artifact.sourcePath { paths.insert(path) }
      }
      if FileManager.default.fileExists(atPath: historyDirectoryURL.path) {
        for directory in try FileManager.default.contentsOfDirectory(at: historyDirectoryURL,
              includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
          let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ASKPageIndexError.invalidArguments("invalid source history directory")
          }
          for url in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
              throw ASKPageIndexError.invalidArguments("invalid source history artifact")
            }
            let artifact = try Self.readJSON(SourceIndexArtifact.self, from: url)
            try SourceIndexArtifactValidator.validate(artifact)
            guard url.standardizedFileURL.resolvingSymlinksInPath().path ==
                historicalArtifactURL(for: artifact.document.sourceID, version: artifact.version)
                    .standardizedFileURL.resolvingSymlinksInPath().path else {
              throw ASKPageIndexError.invalidArguments("non-canonical source history artifact")
            }
            if let path = artifact.sourcePath { paths.insert(path) }
          }
        }
      }
      return paths.sorted()
    }
  }

  func put(backlink: KnowledgeBacklink) throws {
    try withWriteLock {
      try FileManager.default.createDirectory(
        at: backlinksDirectoryURL,
        withIntermediateDirectories: true
      )
      let data = try Self.makeEncoder().encode(backlink)
      try data.write(to: backlinkURL(for: backlink.knowledgeID), options: .atomic)
    }
  }

  func getBacklink(knowledgeID: String) throws -> KnowledgeBacklink? {
    try withReadLock {
      do {
        return try Self.readJSON(KnowledgeBacklink.self, from: backlinkURL(for: knowledgeID))
      } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return nil
      }
    }
  }

  private func withReadLock<T>(_ body: () throws -> T) throws -> T {
    try SourceIndexFileLock.withSharedLock(at: lockURL, label: "source index") {
      try SourceIndexTransaction(root: workspaceURL).requireClean()
      return try body()
    }
  }

  private func withWriteLock<T>(_ body: () throws -> T) throws -> T {
    try SourceIndexFileLock.withExclusiveLock(at: lockURL, label: "source index") {
      try SourceIndexTransaction(root: workspaceURL).recover()
      return try body()
    }
  }

  /// A checksum identifies content, not its copy's mtime or owned generation path.
  /// Keep the first historical artifact immutable; reject different indexed semantics.
  private static func sameIndexedContent(_ lhs: Data, _ rhs: Data) throws -> Bool {
    func normalized(_ data: Data) throws -> SourceIndexArtifact {
      let artifact = try decodeArtifact(from: data)
      try SourceIndexArtifactValidator.validate(artifact)
      var metadata = artifact.evidenceMetadata
      metadata?.sourcePath = nil
      return SourceIndexArtifact(schemaVersion: artifact.schemaVersion,
        document: artifact.document, excerpts: artifact.excerpts,
        version: SourceVersion(checksum: artifact.version.checksum,
          contentLength: artifact.version.contentLength, modifiedAt: nil),
        sourcePath: nil, frontmatter: artifact.frontmatter,
        evidenceMetadata: metadata, extractionQuality: artifact.extractionQuality)
    }
    return try normalized(lhs) == normalized(rhs)
  }

  private func artifactURL(for sourceID: SourceID) -> URL {
    artifactsDirectoryURL.appendingPathComponent(Self.artifactFileName(for: sourceID))
  }

  private func historicalDirectoryURL(for sourceID: SourceID) -> URL {
    historyDirectoryURL.appendingPathComponent(
      Self.sourceDigest(for: sourceID),
      isDirectory: true
    )
  }

  private func historicalArtifactURL(for sourceID: SourceID, version: SourceVersion) -> URL {
    historicalDirectoryURL(for: sourceID).appendingPathComponent(Self.historicalArtifactFileName(for: version))
  }

  private func backlinkURL(for knowledgeID: String) -> URL {
    backlinksDirectoryURL.appendingPathComponent(Self.backlinkFileName(for: knowledgeID))
  }

  private func loadManifest() throws -> [String: SourceIndexManifestEntry] {
    let manifestURL = workspaceURL.appendingPathComponent(Self.manifestFileName)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [:] }
    let manifest = try Self.readJSON(
      [String: SourceIndexManifestEntry].self,
      from: manifestURL
    )

    for (key, entry) in manifest {
      guard key == entry.sourceID.rawValue else {
        throw ASKPageIndexError.invalidArguments(
          "source index manifest key does not match sourceID: \(key)"
        )
      }
      let expectedFileName = Self.artifactFileName(for: entry.sourceID)
      guard entry.artifactFileName == expectedFileName else {
        throw ASKPageIndexError.invalidArguments(
          "source index manifest contains non-canonical artifact path for \(entry.sourceID.rawValue)"
        )
      }
    }
    return manifest
  }

  private static func validate(
    artifact: SourceIndexArtifact,
    against entry: SourceIndexManifestEntry
  ) throws {
    try SourceIndexArtifactValidator.validate(artifact)
    guard
      artifact.document.sourceID == entry.sourceID,
      artifact.document.type == entry.type,
      artifact.document.title == entry.title,
      versionsMatch(artifact.version, entry.version),
      artifact.sourcePath == entry.sourcePath
    else {
      throw ASKPageIndexError.invalidArguments(
        "source index artifact does not match manifest for \(entry.sourceID.rawValue)"
      )
    }
  }

  private static func versionsMatch(_ lhs: SourceVersion, _ rhs: SourceVersion) -> Bool {
    guard lhs.checksum == rhs.checksum, lhs.contentLength == rhs.contentLength else {
      return false
    }

    switch (lhs.modifiedAt, rhs.modifiedAt) {
    case (nil, nil):
      return true
    case (let lhs?, let rhs?):
      return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 1
    default:
      return false
    }
  }

  private static func historicalArtifactFileName(for version: SourceVersion) -> String {
    "ver_\(StableDigest.sha256Hex(Data(version.checksum.utf8))).json"
  }

  private static func backlinkFileName(for knowledgeID: String) -> String {
    let digest = StableDigest.sha256Hex(Data(knowledgeID.utf8))
    return "kb_\(digest).json"
  }

  private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let data = try Data(contentsOf: url)
    return try makeDecoder().decode(type, from: data)
  }

  private static func decodeArtifact(from data: Data) throws -> SourceIndexArtifact {
    try makeDecoder().decode(SourceIndexArtifact.self, from: data)
  }

  private static func readDataIfPresent(at url: URL) throws -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    {
      return nil
    }
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoderFactory.makeEncoder(prettyPrinted: true)
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
  /// Physical locator repair only. Canonical source IDs, root ownership and
  /// every indexed version remain unchanged. Current bytes authenticate matching
  /// historical locators; history freshness still compares its original checksum.
  func relocateSourcePaths(
    _ replacements: [String: URL], allowedDestinationRoots: [URL]
  ) throws -> Int {
    guard !replacements.isEmpty else { return 0 }
    guard replacements.keys.allSatisfy({
      $0.hasPrefix("/") && URL(fileURLWithPath: $0).standardizedFileURL.path == $0
    }), Set(replacements.values.map { $0.standardizedFileURL.path }).count == replacements.count else {
      throw ASKPageIndexError.invalidArguments("Relocation paths must be absolute, canonical and unambiguous")
    }
    return try withWriteLock {
      var manifest = try loadManifest()
      struct StoredArtifact {
        let artifact: SourceIndexArtifact
        let relativePath: String
        let current: Bool
      }
      var stored: [StoredArtifact] = []
      for entry in manifest.values.sorted(by: { $0.sourceID.rawValue < $1.sourceID.rawValue }) {
        let artifact = try Self.readJSON(SourceIndexArtifact.self, from: artifactURL(for: entry.sourceID))
        try Self.validate(artifact: artifact, against: entry)
        stored.append(.init(artifact: artifact, relativePath: "artifacts/\(entry.artifactFileName)", current: true))
      }
      if FileManager.default.fileExists(atPath: historyDirectoryURL.path) {
        for directory in try FileManager.default.contentsOfDirectory(at: historyDirectoryURL,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).sorted(by: { $0.path < $1.path }) {
          let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ASKPageIndexError.invalidArguments("Invalid source history directory during relocation")
          }
          for url in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).sorted(by: { $0.path < $1.path }) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
              throw ASKPageIndexError.invalidArguments("Invalid source history artifact during relocation")
            }
            let artifact = try Self.readJSON(SourceIndexArtifact.self, from: url)
            try SourceIndexArtifactValidator.validate(artifact)
            guard url.standardizedFileURL == historicalArtifactURL(for: artifact.document.sourceID, version: artifact.version) else {
              throw ASKPageIndexError.invalidArguments("Non-canonical source history artifact during relocation")
            }
            stored.append(.init(artifact: artifact,
              relativePath: "history/\(directory.lastPathComponent)/\(url.lastPathComponent)", current: false))
          }
        }
      }
      var writes: [SourceIndexTransaction.Write] = []
      var checked: [String: (checksum: String, length: Int)] = [:]
      struct CurrentLocatorKey: Hashable { let sourceID: SourceID; let path: String }
      var verifiedCurrent: Set<CurrentLocatorKey> = []
      for item in stored {
        let artifact = item.artifact
        guard let oldPath = artifact.sourcePath, let destination = replacements[oldPath],
              oldPath != destination.standardizedFileURL.path else { continue }
        let newPath = destination.standardizedFileURL.path
        if checked[oldPath] == nil {
          try SourceRelocationFileReader.requireMissing(oldPath)
          let data = try SourceRelocationFileReader.read(destination,
            allowedRoots: allowedDestinationRoots, expectedBytes: artifact.version.contentLength)
          checked[oldPath] = (StableDigest.sha256Hex(data), data.count)
        }
        guard let current = checked[oldPath] else {
          throw ASKPageIndexError.invalidArguments("Relocation byte verification is unavailable")
        }
        let key = CurrentLocatorKey(sourceID: artifact.document.sourceID, path: oldPath)
        let exactBytes = current.checksum == artifact.version.checksum && current.length == artifact.version.contentLength
        guard exactBytes || (!item.current && verifiedCurrent.contains(key)) else {
          throw ASKPageIndexError.invalidArguments("Relocated bytes do not match current evidence or an authenticated historical locator")
        }
        // Current entries are visited before history. A mutable original can
        // legitimately differ from old indexed versions; relocating that same
        // ID+path does not change their checksums or certify them as current.
        if item.current { verifiedCurrent.insert(key) }
        var metadata = artifact.evidenceMetadata
        metadata?.sourcePath = newPath
        let updated = SourceIndexArtifact(schemaVersion: artifact.schemaVersion,
          document: artifact.document, excerpts: artifact.excerpts, version: artifact.version,
          sourcePath: newPath, frontmatter: artifact.frontmatter, evidenceMetadata: metadata,
          extractionQuality: artifact.extractionQuality)
        try SourceIndexArtifactValidator.validate(updated)
        writes.append(.init(relativePath: item.relativePath, data: try Self.makeEncoder().encode(updated)))
        if item.current {
          guard let entry = manifest[artifact.document.sourceID.rawValue] else {
            throw ASKPageIndexError.invalidArguments("Current relocation entry disappeared")
          }
          manifest[entry.sourceID.rawValue] = SourceIndexManifestEntry(
            sourceID: entry.sourceID, artifactFileName: entry.artifactFileName,
            type: entry.type, title: entry.title, version: entry.version,
            sourcePath: newPath, sourceRootIdentity: entry.sourceRootIdentity)
        }
      }
      guard !writes.isEmpty else { return 0 }
      let relocatedCount = writes.count
      // Publish the manifest even for history-only changes: invalidates readers
      // and keeps the existing transaction's mandatory commit ordering.
      writes.append(.init(relativePath: Self.manifestFileName, data: try Self.makeEncoder().encode(manifest)))
      try SourceIndexTransaction(root: workspaceURL).publish(writes)
      return relocatedCount
    }
  }

}
