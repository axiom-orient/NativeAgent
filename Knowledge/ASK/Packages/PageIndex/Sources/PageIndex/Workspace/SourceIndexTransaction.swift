import Foundation

/// Recoverable multi-file publication under SourceIndexFileLock. The pending
/// record owns the before-state; removing it is the commit point. This closes
/// process-death recovery, not storage-device power-loss durability.
struct SourceIndexTransaction {
  static let pendingFileName = ".source-index-pending.json"
  let root: URL

  struct Write {
    let relativePath: String
    let data: Data?
  }

  private struct Before: Codable {
    let path: String
    let data: Data?
  }

  private struct Pending: Codable {
    let version: Int
    let files: [Before]
  }

  private var pendingURL: URL { root.appendingPathComponent(Self.pendingFileName) }

  func requireClean() throws {
    if try readIfPresent(pendingURL) != nil {
      throw failure("Interrupted publication requires SourceIndexStore.recoverPendingWrite() or a new indexWorkspace operation")
    }
  }

  /// Idempotent rollback; the marker survives every incomplete recovery.
  @discardableResult
  func recover() throws -> Bool {
    guard let data = try readIfPresent(pendingURL) else { return false }
    let pending = try JSONDecoder().decode(Pending.self, from: data)
    guard pending.version == 1, !pending.files.isEmpty,
          pending.files.last?.path == SourceIndexWorkspace.manifestFileName,
          Set(pending.files.map(\.path)).count == pending.files.count else {
      throw failure("Invalid pending source transaction; preserve it for inspection")
    }
    // Validate every target before restoring anything, including persisted input.
    for file in pending.files { _ = try target(for: file.path) }
    for file in pending.files {
      try restore(file.data, at: target(for: file.path))
    }
    try FileManager.default.removeItem(at: pendingURL)
    return true
  }

  func publish(_ writes: [Write]) throws {
    try requireClean()
    let targets = try writes.map { write in
      (
        path: write.relativePath,
        data: write.data,
        url: try target(for: write.relativePath)
      )
    }
    var before: [Before] = []
    for target in targets {
      before.append(Before(path: target.path, data: try readIfPresent(target.url)))
    }
    guard before.last?.path == SourceIndexWorkspace.manifestFileName,
          Set(before.map(\.path)).count == before.count else {
      throw failure("Source transaction must have unique targets and publish the manifest last")
    }
    let data = try JSONEncoder().encode(Pending(version: 1, files: before))
    // Existing pending-file links are rejected by requireClean/readIfPresent.
    try data.write(to: pendingURL, options: .atomic)
    do {
      for target in targets { try restore(target.data, at: target.url) }
      try FileManager.default.removeItem(at: pendingURL)
    } catch {
      let primary = String(describing: error)
      do { try recover() }
      catch { throw failure("Publication failed: \(primary); recovery incomplete: \(error). Pending record retained") }
      throw failure("Publication failed and previous state was restored: \(primary)")
    }
  }

  private func target(for relative: String) throws -> URL {
    let hex = "[0-9a-f]{64}"
    let pattern = "^(_source_manifest\\.json|artifacts/src_\(hex)\\.json|history/\(hex)/ver_\(hex)\\.json)$"
    guard relative.range(of: pattern, options: .regularExpression) != nil else {
      throw failure("Invalid source transaction target: \(relative)")
    }
    var current = root
    let parts = relative.split(separator: "/")
    for (index, part) in parts.enumerated() {
      current.appendPathComponent(String(part))
      if let type = try fileType(current) {
        let expected: FileAttributeType = index == parts.count - 1 ? .typeRegular : .typeDirectory
        guard type == expected else { throw failure("Source transaction target has an invalid file type: \(current.path)") }
      }
    }
    return current
  }

  private func readIfPresent(_ url: URL) throws -> Data? {
    guard let type = try fileType(url) else { return nil }
    guard type == .typeRegular else { throw failure("Source transaction input must be a regular file: \(url.path)") }
    return try Data(contentsOf: url)
  }

  private func fileType(_ url: URL) throws -> FileAttributeType? {
    do { return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
    catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
  }

  private func restore(_ data: Data?, at url: URL) throws {
    if let data {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } else if try fileType(url) != nil {
      try FileManager.default.removeItem(at: url)
    }
  }

  private func failure(_ detail: String) -> ASKPageIndexError {
    .processFailure(command: "source index transaction", exitCode: 1, stderr: detail)
  }
}
