import Foundation

/// Bounded JSON admission used only by credential exchange and account HTTP I/O.
enum ChatGPTAccountPayload {
  static let maximumResponseBytes = 1 * 1_024 * 1_024

  static func object(_ data: Data) throws -> [String: Any] {
    guard !data.isEmpty, data.count <= maximumResponseBytes,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw ChatGPTFailure(.malformedResponse) }
    return object
  }
}
