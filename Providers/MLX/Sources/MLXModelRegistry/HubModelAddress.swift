import Foundation

/// A model repository copied from a Hugging Face page or entered as `namespace/repository`.
///
/// The address may include `/tree/<revision>` or `/commit/<sha>`. A branch or tag is only an
/// installation request; callers resolve it to an immutable commit before downloading files.
public struct MLXHubModelAddress: Hashable, Sendable {
  public static let maximumAddressUTF8Bytes = 2_048
  public static let maximumRevisionUTF8Bytes = 256

  public let repositoryID: String
  public let revision: String?

  public init(_ value: String) throws {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= Self.maximumAddressUTF8Bytes else {
      throw MLXHubModelError.invalidAddress
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
      else { throw MLXHubModelError.invalidAddress }
      segments = try Self.pathSegments(components.percentEncodedPath)
    } else {
      guard !value.contains("?") && !value.contains("#") else {
        throw MLXHubModelError.invalidAddress
      }
      segments = try Self.pathSegments("/" + value)
    }

    guard segments.count == 2 || segments.count == 4,
      Self.isValidRepositoryPart(segments[0]), Self.isValidRepositoryPart(segments[1])
    else { throw MLXHubModelError.invalidAddress }

    let repositoryID = "\(segments[0])/\(segments[1])"
    if segments.count == 2 {
      self.repositoryID = repositoryID
      self.revision = nil
      return
    }

    let action = segments[2]
    let revision = segments[3]
    guard action == "tree" || action == "commit", Self.isValidRevision(revision) else {
      throw MLXHubModelError.invalidAddress
    }
    if action == "commit", !Self.isCommitHash(revision) {
      throw MLXHubModelError.invalidAddress
    }
    self.repositoryID = repositoryID
    self.revision = revision
  }

  private static func looksLikeURL(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    return value.contains("://") || lowercased.hasPrefix("huggingface.co/")
      || lowercased.hasPrefix("www.huggingface.co/")
  }

  private static func urlString(_ value: String) -> String {
    value.contains("://") ? value : "https://\(value)"
  }

  private static func pathSegments(_ path: String) throws -> [String] {
    var encodedSegments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard encodedSegments.first == "" else { throw MLXHubModelError.invalidAddress }
    encodedSegments.removeFirst()
    if encodedSegments.last == "" { encodedSegments.removeLast() }
    guard !encodedSegments.isEmpty, !encodedSegments.contains("") else {
      throw MLXHubModelError.invalidAddress
    }
    return try encodedSegments.map { encoded in
      guard let decoded = encoded.removingPercentEncoding, !decoded.isEmpty,
        !decoded.contains("\\"), !decoded.contains("\0")
      else { throw MLXHubModelError.invalidAddress }
      return decoded
    }
  }

  private static func isValidRepositoryPart(_ value: String) -> Bool {
    guard (1...MLXHubReference.maximumRepositoryPartUTF8Bytes).contains(value.utf8.count),
      value != ".", value != "..", !value.contains("..")
    else { return false }
    return value.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || byte == 45 || byte == 46 || byte == 95
    }
  }

  private static func isValidRevision(_ value: String) -> Bool {
    guard (1...maximumRevisionUTF8Bytes).contains(value.utf8.count),
      !value.hasPrefix("/"), !value.hasSuffix("/"), !value.contains("//"),
      !value.contains(".."), !value.contains("@{"), !value.hasSuffix(".")
    else { return false }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".lock") })
    else { return false }
    return value.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || byte == 45 || byte == 46 || byte == 47 || byte == 95
    }
  }

  private static func isCommitHash(_ value: String) -> Bool {
    value.utf8.count == MLXHubReference.gitCommitHexCharacters
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
      }
  }
}
