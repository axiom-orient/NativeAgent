import Foundation
import CoreFoundation

enum ChatGPTCredentialLimits {
  static let maximumTokenUTF8Bytes = 64 * 1_024
  static let maximumAccountIDUTF8Bytes = 512
  static let maximumMetadataUTF8Bytes = 512
  static let maximumCredentialNamespaceUTF8Bytes = 256
  static let maximumJWTPayloadBytes = 64 * 1_024
  static let minimumExpiresInSeconds: TimeInterval = 60
  static let maximumExpiresInSeconds: TimeInterval = 31_536_000
}

struct ChatGPTTokenSet: Codable, Hashable, Sendable {
  let accessToken: String
  let refreshToken: String
  let idToken: String
  let expiresAt: Date
  let account: ChatGPTAccount

  func validate() throws {
    for token in [accessToken, refreshToken, idToken] {
      guard !token.isEmpty, token.utf8.count <= ChatGPTCredentialLimits.maximumTokenUTF8Bytes,
        !token.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F })
      else { throw ChatGPTFailure(.malformedResponse) }
    }
    guard ChatGPTClaims.validAccountID(account.accountID),
      expiresAt.timeIntervalSinceReferenceDate.isFinite
    else {
      throw ChatGPTFailure(.malformedResponse)
    }
  }
}

protocol ChatGPTCredentialStoring: Sendable {
  func load() throws -> ChatGPTTokenSet?
  func save(_ value: ChatGPTTokenSet) throws
  func delete() throws
}

enum ChatGPTClaims {
  static func account(idToken: String) throws -> ChatGPTAccount {
    let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, !parts[1].isEmpty else {
      throw ChatGPTFailure(.malformedResponse)
    }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded),
      data.count <= ChatGPTCredentialLimits.maximumJWTPayloadBytes,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let auth = root["https://api.openai.com/auth"] as? [String: Any],
      let accountID = auth["chatgpt_account_id"] as? String,
      validAccountID(accountID)
    else { throw ChatGPTFailure(.malformedResponse) }
    let plan = (auth["chatgpt_plan_type"] as? String).flatMap(Self.boundedMetadata)
    let profile = root["https://api.openai.com/profile"] as? [String: Any]
    let email = ((root["email"] as? String) ?? (profile?["email"] as? String))
      .flatMap(Self.boundedMetadata)
    return ChatGPTAccount(accountID: accountID, plan: plan, email: email)
  }

  static func validAccountID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= ChatGPTCredentialLimits.maximumAccountIDUTF8Bytes
      && value.unicodeScalars.allSatisfy { (0x21..<0x7F).contains($0.value) }
  }

  static func expiration(accessToken: String, expiresIn: TimeInterval?, now: Date = Date()) throws -> Date {
    let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 3 {
      var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
      encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
      if let data = Data(base64Encoded: encoded),
        data.count <= ChatGPTCredentialLimits.maximumJWTPayloadBytes,
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let number = root["exp"] as? NSNumber,
        CFGetTypeID(number) == CFNumberGetTypeID()
      {
        let seconds = number.doubleValue
        if seconds.isFinite, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
      }
    }
    guard let expiresIn, expiresIn.isFinite,
      (ChatGPTCredentialLimits.minimumExpiresInSeconds...ChatGPTCredentialLimits.maximumExpiresInSeconds)
        .contains(expiresIn)
    else { throw ChatGPTFailure(.malformedResponse) }
    return now.addingTimeInterval(expiresIn)
  }

  private static func boundedMetadata(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= ChatGPTCredentialLimits.maximumMetadataUTF8Bytes,
      !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { return nil }
    return value
  }
}
