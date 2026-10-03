import Foundation

public enum HubModelAddressError: Error, Equatable, Sendable {
  case invalidAddress
}

/// A Hugging Face model-page address. Floating refs are resolved by an importer before download.
public struct HubModelAddress: Hashable, Sendable {
  public static let maximumAddressUTF8Bytes = 2_048
  public static let maximumRevisionUTF8Bytes = 256

  public let repositoryID: String
  public let revision: String?

  public init(_ value: String) throws {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= Self.maximumAddressUTF8Bytes else {
      throw HubModelAddressError.invalidAddress
    }

    let segments: [String]
    if Self.looksLikeURL(value) {
      guard let components = URLComponents(string: Self.urlString(value)),
        components.scheme?.lowercased() == "https",
        let host = components.host?.lowercased(),
        ["huggingface.co", "www.huggingface.co"].contains(host),
        components.user == nil, components.password == nil,
        components.port == nil || components.port == 443,
        components.query == nil, components.fragment == nil
      else { throw HubModelAddressError.invalidAddress }
      segments = try Self.pathSegments(components.percentEncodedPath)
    } else {
      guard !value.contains("?") && !value.contains("#") else {
        throw HubModelAddressError.invalidAddress
      }
      segments = try Self.pathSegments("/" + value)
    }

    guard segments.count == 2 || segments.count == 4 else {
      throw HubModelAddressError.invalidAddress
    }
    let repositoryID = "\(segments[0])/\(segments[1])"
    guard HubRepositorySyntax.isValidRepositoryID(repositoryID) else {
      throw HubModelAddressError.invalidAddress
    }

    self.repositoryID = repositoryID
    guard segments.count == 4 else {
      revision = nil
      return
    }
    let action = segments[2]
    let requestedRevision = segments[3]
    guard action == "tree" || action == "commit",
      HubRepositorySyntax.isValidRevision(
        requestedRevision, maximumUTF8Bytes: Self.maximumRevisionUTF8Bytes),
      action != "commit" || HubRepositorySyntax.isCommit(requestedRevision)
    else { throw HubModelAddressError.invalidAddress }
    revision = requestedRevision
  }

  public var pageAddress: String {
    guard let revision else { return repositoryID }
    let action = HubRepositorySyntax.isCommit(revision) ? "commit" : "tree"
    return "https://huggingface.co/\(repositoryID)/\(action)/\(revision)"
  }

  private static func looksLikeURL(_ value: String) -> Bool {
    let lowered = value.lowercased()
    return value.contains("://") || lowered.hasPrefix("huggingface.co/")
      || lowered.hasPrefix("www.huggingface.co/")
  }

  private static func urlString(_ value: String) -> String {
    value.contains("://") ? value : "https://\(value)"
  }

  private static func pathSegments(_ path: String) throws -> [String] {
    var encoded = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard encoded.first == "" else { throw HubModelAddressError.invalidAddress }
    encoded.removeFirst()
    if encoded.last == "" { encoded.removeLast() }
    guard !encoded.isEmpty, !encoded.contains("") else { throw HubModelAddressError.invalidAddress }
    return try encoded.map { part in
      guard let decoded = part.removingPercentEncoding, !decoded.isEmpty,
        !decoded.contains("/"), !decoded.contains("\\"), !decoded.contains("\0")
      else { throw HubModelAddressError.invalidAddress }
      return decoded
    }
  }

}
