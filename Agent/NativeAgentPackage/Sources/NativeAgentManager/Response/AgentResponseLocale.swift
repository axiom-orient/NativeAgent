import Foundation

/// Locale matching for response data, not language detection or a BCP 47 registry validator.
/// Exact tag, then progressively shorter parents; never infer a sibling script or region.
enum AgentResponseLocale {
  static func normalized(_ identifier: String) -> String {
    identifier.replacingOccurrences(of: "_", with: "-").lowercased()
  }

  static func bestMatch(for identifier: String?, available: [String]) -> String? {
    guard let identifier else { return nil }
    let tags = Set(available.map(normalized))
    var parts = normalized(identifier).split(separator: "-")
    while !parts.isEmpty {
      let candidate = parts.joined(separator: "-")
      if tags.contains(candidate) { return candidate }
      parts.removeLast()
      // RFC 4647 §3.4: remove a trailing extension/private-use singleton with its value.
      if parts.last?.count == 1 { parts.removeLast() }
    }
    return nil
  }
}
