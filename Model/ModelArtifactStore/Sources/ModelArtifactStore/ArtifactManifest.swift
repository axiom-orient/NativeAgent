import CryptoKit
import Foundation

public enum ArtifactStoreError: Error, Equatable, Sendable {
  case invalidManifest
  case invalidPath
  case unsupportedEntry
  case limitExceeded
  case sizeMismatch
  case digestMismatch
  case missingFile
  case busy
  case consumedStaging
  case storageFailure
}

public struct ArtifactDigest: RawRepresentable, Codable, Hashable, Sendable {
  public static let hexadecimalUTF8Bytes = 64
  public let rawValue: String
  public init?(rawValue: String) {
    guard rawValue.utf8.count == Self.hexadecimalUTF8Bytes,
      rawValue.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    self.rawValue = rawValue
  }
}

public struct ArtifactEntry: Codable, Hashable, Sendable {
  public let path: String
  public let byteCount: UInt64
  public let sha256: ArtifactDigest

  public init(path: String, byteCount: UInt64, sha256: ArtifactDigest) throws {
    try ArtifactManifest.validate(path: path)
    self.path = path
    self.byteCount = byteCount
    self.sha256 = sha256
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      path: values.decode(String.self, forKey: .path),
      byteCount: values.decode(UInt64.self, forKey: .byteCount),
      sha256: values.decode(ArtifactDigest.self, forKey: .sha256))
  }
}

public struct ArtifactManifest: Codable, Hashable, Sendable {
  public static let formatVersion = 1
  public static let maximumArtifactIDUTF8Bytes = 128
  public static let maximumFileCount = 100_000
  public static let maximumPathUTF8Bytes = 4_096
  public static let maximumPathComponents = 32
  public static let maximumPathComponentUTF8Bytes = 255
  private static let digestDomain = "NativeAgent-ARTIFACT-MANIFEST-V1\0"
  public let formatVersion: Int
  public let artifactID: String
  public let files: [ArtifactEntry]
  public let totalBytes: UInt64
  public let manifestDigest: ArtifactDigest

  public init(artifactID: String, files: [ArtifactEntry]) throws {
    guard (1...Self.maximumArtifactIDUTF8Bytes).contains(artifactID.utf8.count),
      artifactID.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
      }), artifactID != ".", artifactID != "..",
      !files.isEmpty, files.count <= Self.maximumFileCount
    else { throw ArtifactStoreError.invalidManifest }
    var previousPath: String?
    var seenPaths: Set<String> = []
    var total: UInt64 = 0
    for file in files {
      if let previousPath,
        !previousPath.utf8.lexicographicallyPrecedes(file.path.utf8)
      {
        throw ArtifactStoreError.invalidManifest
      }
      guard seenPaths.insert(file.path).inserted else {
        throw ArtifactStoreError.invalidManifest
      }
      previousPath = file.path
      try Self.validate(path: file.path)
      let (next, overflow) = total.addingReportingOverflow(file.byteCount)
      guard !overflow, next <= UInt64(Int64.max) else { throw ArtifactStoreError.limitExceeded }
      total = next
    }
    formatVersion = Self.formatVersion
    self.artifactID = artifactID
    self.files = files
    totalBytes = total
    manifestDigest = Self.digest(artifactID: artifactID, files: files, totalBytes: total)
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .formatVersion) == Self.formatVersion else {
      throw ArtifactStoreError.invalidManifest
    }
    try self.init(
      artifactID: values.decode(String.self, forKey: .artifactID),
      files: values.decode([ArtifactEntry].self, forKey: .files))
    guard try values.decode(UInt64.self, forKey: .totalBytes) == totalBytes,
      try values.decode(ArtifactDigest.self, forKey: .manifestDigest) == manifestDigest
    else { throw ArtifactStoreError.invalidManifest }
  }

  public func validate() throws {
    let rebuilt = try Self(artifactID: artifactID, files: files)
    guard formatVersion == Self.formatVersion, totalBytes == rebuilt.totalBytes,
      manifestDigest == rebuilt.manifestDigest
    else { throw ArtifactStoreError.invalidManifest }
  }

  static func validate(path: String) throws {
    let bytes = path.utf8
    guard (1...Self.maximumPathUTF8Bytes).contains(bytes.count), !path.hasPrefix("/"), !path.hasSuffix("/"),
      !path.contains("\\"), !path.contains("\0"), !path.hasPrefix(".native-agent-")
    else { throw ArtifactStoreError.invalidPath }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count <= Self.maximumPathComponents,
      components.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= Self.maximumPathComponentUTF8Bytes
      })
    else { throw ArtifactStoreError.invalidPath }
  }

  private static func digest(artifactID: String, files: [ArtifactEntry], totalBytes: UInt64)
    -> ArtifactDigest
  {
    var hasher = SHA256()
    hasher.update(data: Data(Self.digestDomain.utf8))
    update(artifactID, into: &hasher)
    update(String(totalBytes), into: &hasher)
    for file in files {
      update(file.path, into: &hasher)
      update(String(file.byteCount), into: &hasher)
      update(file.sha256.rawValue, into: &hasher)
    }
    return ArtifactDigest(
      rawValue: hasher.finalize().map { String(format: "%02x", $0) }.joined())!
  }

  private static func update(_ value: String, into hasher: inout SHA256) {
    let bytes = Data(value.utf8)
    hasher.update(data: Data("\(bytes.count):".utf8))
    hasher.update(data: bytes)
  }
}
