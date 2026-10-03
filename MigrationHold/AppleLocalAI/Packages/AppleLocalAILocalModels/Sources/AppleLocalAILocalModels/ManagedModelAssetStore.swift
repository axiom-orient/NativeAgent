import Foundation

/// Immutable import identity. The containing app resolves the root each launch;
/// an iOS sandbox container's absolute path is never the persisted identity.
public struct ManagedModelAsset: Codable, Equatable, Sendable {
  public let id: UUID
  public let fileName: String

  fileprivate init(id: UUID, fileName: String) {
    self.id = id
    self.fileName = fileName
  }
}

public enum ManagedModelAssetError: Error, LocalizedError {
  case invalidSource
  case symbolicLinkOrSpecialFile(String)
  case invalidReference
  case rootInsideSource
  case cleanupFailed(primary: String, cleanup: String)

  public var errorDescription: String? {
    switch self {
    case .invalidSource: "A readable local file or directory is required."
    case .symbolicLinkOrSpecialFile(let path):
      "Symbolic links and special files are not admitted: \(path)"
    case .invalidReference: "The imported model reference is invalid or missing."
    case .rootInsideSource: "The model import root cannot be inside the selected source."
    case .cleanupFailed(let primary, let cleanup):
      "Import failed: \(primary). Staging cleanup also failed: \(cleanup)"
    }
  }
}

/// Filesystem mechanism only. Format validation is supplied by the model adapter.
/// Security-scoped access and asynchronous operation ownership belong to the app.
/// A successful import adds a unique immutable directory, never replaces a model
/// still in use. It proves local admission, not successful model load/inference.
public struct ManagedModelAssetStore: Sendable {
  public let root: URL

  public init(root: URL) { self.root = root.standardizedFileURL }

  public func resolve(_ asset: ManagedModelAsset) throws -> URL {
    guard validFileName(asset.fileName), root.isFileURL else {
      throw ManagedModelAssetError.invalidReference
    }
    let parent = root.appendingPathComponent(asset.id.uuidString, isDirectory: true)
    let url = parent.appendingPathComponent(asset.fileName)
    try rejectLinksAndSpecialFiles(at: root, recursively: false)
    try rejectLinksAndSpecialFiles(at: parent, recursively: false)
    try rejectLinksAndSpecialFiles(at: url, recursively: false)
    return url
  }

  /// Call off the UI actor. Cancellation is checked at phase boundaries, including
  /// after copy (FileManager.copyItem itself is not cooperatively cancellable).
  public func importAsset(
    from source: URL,
    validate: @Sendable (URL) throws -> Void
  ) throws -> ManagedModelAsset {
    let files = FileManager.default
    guard source.isFileURL, root.isFileURL,
      validFileName(source.lastPathComponent),
      files.isReadableFile(atPath: source.path)
    else { throw ManagedModelAssetError.invalidSource }

    let source = source.standardizedFileURL
    let canonicalSource = source.resolvingSymlinksInPath()
    let canonicalRoot = root.resolvingSymlinksInPath()
    guard !Self.isContained(canonicalRoot, in: canonicalSource) else {
      throw ManagedModelAssetError.rootInsideSource
    }
    try Task.checkCancellation()
    try rejectLinksAndSpecialFiles(at: source, recursively: true)
    try validate(source)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    try rejectLinksAndSpecialFiles(at: root, recursively: false)

    let asset = ManagedModelAsset(id: UUID(), fileName: source.lastPathComponent)
    let staging = root.appendingPathComponent(".staging-\(asset.id.uuidString)", isDirectory: true)
    let destination = root.appendingPathComponent(asset.id.uuidString, isDirectory: true)
    let stagedAsset = staging.appendingPathComponent(asset.fileName)
    try files.createDirectory(at: staging, withIntermediateDirectories: false)
    do {
      try Task.checkCancellation()
      try files.copyItem(at: source, to: stagedAsset)
      try Task.checkCancellation()
      try rejectLinksAndSpecialFiles(at: stagedAsset, recursively: true)
      try validate(stagedAsset)
      try Task.checkCancellation()
      // Staging and destination share a parent/filesystem. No in-place overwrite.
      try files.moveItem(at: staging, to: destination)
      return asset
    } catch {
      let primary = error
      do { try files.removeItem(at: staging) } catch {
        throw ManagedModelAssetError.cleanupFailed(
          primary: primary.localizedDescription, cleanup: error.localizedDescription)
      }
      throw primary
    }
  }

  /// Only for an import that has NOT been published as the selected asset.
  /// No general deletion API: deleting an asset used by a session needs leases.
  public func discardUnpublished(_ asset: ManagedModelAsset) throws {
    _ = try resolve(asset)
    try FileManager.default.removeItem(
      at: root.appendingPathComponent(asset.id.uuidString, isDirectory: true))
  }

  public static func isContained(_ child: URL, in parent: URL) -> Bool {
    let parentParts = parent.standardizedFileURL.pathComponents
    let childParts = child.standardizedFileURL.pathComponents
    return childParts.count >= parentParts.count
      && Array(childParts.prefix(parentParts.count)) == parentParts
  }

  private func validFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
      && !name.contains("\\") && !name.contains("\0")
  }

  private func rejectLinksAndSpecialFiles(at url: URL, recursively: Bool) throws {
    let files = FileManager.default
    let attributes = try files.attributesOfItem(atPath: url.path)
    guard let kind = attributes[.type] as? FileAttributeType,
      kind == .typeRegular || kind == .typeDirectory
    else { throw ManagedModelAssetError.symbolicLinkOrSpecialFile(url.path) }
    guard recursively, kind == .typeDirectory else { return }
    // Walk explicitly: directory enumeration errors must not become silent success.
    for child in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
      try Task.checkCancellation()
      try rejectLinksAndSpecialFiles(at: child, recursively: true)
    }
  }
}
