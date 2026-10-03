import Foundation
import NativeAgentStore

/// Canonical persistent root for durable sessions and managed-agent data.
///
/// `AgentStorage` remains the execution-store contract. `AgentDataStore` adds the
/// stable root URL used by higher-level agent management so Soul, Memory and Skills
/// do not invent independent Application Support locations.
public struct AgentDataStore: Sendable {
  public let rootURL: URL
  public let storage: AgentStorage

  public init(rootURL: URL, storage: AgentStorage) {
    self.rootURL = rootURL.standardizedFileURL
    self.storage = storage
  }

  public static func applicationSupport(
    appName: String,
    appGroupIdentifier: String? = nil,
    appGroupContainerURL: URL? = nil,
    subdirectoryName: String = StoreLayout.defaultSubdirectoryName,
    executionClaimStore: (any SessionExecutionClaimStore)? = nil
  ) throws -> AgentDataStore {
    let root = try AgentStorage.applicationSupportRootURL(
      appName: appName,
      appGroupIdentifier: appGroupIdentifier,
      appGroupContainerURL: appGroupContainerURL,
      subdirectoryName: subdirectoryName
    )
    let storage = AgentStorage(rootURL: root, executionClaimStore: executionClaimStore)
    return AgentDataStore(rootURL: root, storage: storage)
  }

  /// Deterministic root for tests, previews and host-owned directories.
  public static func directory(_ rootURL: URL) -> AgentDataStore {
    let root = rootURL.standardizedFileURL
    return AgentDataStore(rootURL: root, storage: AgentStorage.directory(root))
  }
}
