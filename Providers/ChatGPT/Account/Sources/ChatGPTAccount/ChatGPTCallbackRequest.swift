import Foundation

enum ChatGPTLocalhostCallbackError: Error, LocalizedError, Sendable {
  case alreadyStarted
  case callbackAlreadyConsumed
  case invalidRequest
  case authorizationTimedOut
  case callbackPortsOccupied
  case shutdownTimedOut

  var errorDescription: String? {
    switch self {
    case .alreadyStarted:
      "The sign-in callback listener is already active."
    case .callbackAlreadyConsumed:
      "The sign-in callback was already received."
    case .invalidRequest:
      "The sign-in callback request was invalid."
    case .authorizationTimedOut:
      "The authorization request timed out."
    case .callbackPortsOccupied:
      "The configured sign-in callback ports are occupied."
    case .shutdownTimedOut:
      "The sign-in callback listener or its connections did not confirm shutdown."
    }
  }
}

/// Internal safety policy, not an OAuth wire identity or user setting.
enum ChatGPTCallbackPolicy {
  static let maximumRequestBytes = 16 * 1_024
  static let maximumConcurrentRequests = 8
  static let shutdownTimeout: TimeInterval = 5
}

/// Pure incremental parsing. A complete invalid header is never treated as more input.
enum ChatGPTCallbackRequest {
  enum ParseResult: Equatable, Sendable {
    case incomplete
    case invalid
    case callback(URL)
  }

  static func parse(_ data: Data, matching redirectURI: URL) -> ParseResult {
    guard data.count <= ChatGPTCallbackPolicy.maximumRequestBytes,
      (try? ChatGPTProtocolProfile.validateCallbackRedirectURI(redirectURI)) != nil
    else { return .invalid }
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerEnd = data.range(of: delimiter) else {
      return data.count == ChatGPTCallbackPolicy.maximumRequestBytes ? .invalid : .incomplete
    }
    guard headerEnd.upperBound == data.endIndex,
      let request = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
    else { return .invalid }
    let lines = request.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .invalid }
    let fields = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0] == "GET", fields[2] == "HTTP/1.1" else { return .invalid }
    let target = String(fields[1])
    guard target.hasPrefix("/"), !target.hasPrefix("//"),
      target.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7F })
    else { return .invalid }

    var hostHeader: String?
    var contentLengthSeen = false
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":"), separator != line.startIndex else {
        return .invalid
      }
      let name = line[..<separator]
      guard name.utf8.allSatisfy(isHeaderNameByte) else { return .invalid }
      let rawValue = line[line.index(after: separator)...]
      guard rawValue.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 0x20 && $0.value != 0x7F) })
      else { return .invalid }
      let value = rawValue.trimmingCharacters(in: .whitespaces)
      switch name.lowercased() {
      case "host":
        guard hostHeader == nil else { return .invalid }
        hostHeader = value
      case "content-length":
        guard !contentLengthSeen, value == "0" else { return .invalid }
        contentLengthSeen = true
      case "transfer-encoding":
        return .invalid // This one-shot GET callback never accepts a body or a second request.
      default: break
      }
    }
    guard let host = redirectURI.host?.lowercased(), let port = redirectURI.port,
      hostHeader == "\(host):\(port)",
      let components = URLComponents(string: "http://\(host):\(port)\(target)"),
      components.scheme == redirectURI.scheme, components.host?.lowercased() == host,
      components.port == port, components.percentEncodedPath == redirectURI.path,
      components.user == nil, components.password == nil, components.fragment == nil,
      let url = components.url
    else { return .invalid }
    return .callback(url)
  }

  private static func isHeaderNameByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
      || "!#$%&'*+-.^_`|~".utf8.contains(byte)
  }
}
