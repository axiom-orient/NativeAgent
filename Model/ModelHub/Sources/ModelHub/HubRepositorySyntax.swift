import Foundation

enum HubRepositorySyntax {
  static let maximumRepositoryIDUTF8Bytes = 96

  static func isValidRepositoryID(_ value: String) -> Bool {
    guard (1...maximumRepositoryIDUTF8Bytes).contains(value.utf8.count) else { return false }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2 && parts.allSatisfy { isValidRepositoryPart(String($0)) }
  }

  static func isValidRepositoryPart(_ value: String) -> Bool {
    guard !value.isEmpty,
      !value.hasPrefix("."), !value.hasPrefix("-"),
      !value.hasSuffix("."), !value.hasSuffix("-"),
      !value.hasSuffix(".git"),
      !value.contains(".."), !value.contains("--")
    else { return false }

    return value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || $0 == 45 || $0 == 46 || $0 == 95
    }
  }

  static func isValidRevision(_ value: String, maximumUTF8Bytes: Int) -> Bool {
    guard (1...maximumUTF8Bytes).contains(value.utf8.count),
      value != "@", !value.hasPrefix("/"), !value.hasSuffix("/"),
      !value.contains("//"), !value.contains(".."), !value.contains("@{"),
      !value.hasSuffix(".")
    else { return false }

    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard
      parts.allSatisfy({
        !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
      })
    else { return false }

    return value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || $0 == 45 || $0 == 46 || $0 == 47 || $0 == 95
    }
  }

  static func isCommit(_ value: String) -> Bool {
    value.utf8.count == 40
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }
  }
}
