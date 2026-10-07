import Foundation
import LanguageModelCore

/// Decodes the current engine's JSON response envelope at the vendor boundary.
/// Classification precedes parsing: malformed JSON is never repaired or retried.
enum LeapJSONOutput {
  static let maximumEnvelopeBytes = 16

  static func decode(_ native: String, maximumBytes: Int) throws -> String {
    let trimmed = native.trimmingCharacters(in: .whitespacesAndNewlines)
    let json: String
    if trimmed.hasPrefix("```") {
      guard trimmed.hasPrefix("```json\n"), trimmed.hasSuffix("\n```") else {
        throw malformed()
      }
      json = String(trimmed.dropFirst(8).dropLast(4))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      json = trimmed
    }
    guard json.utf8.count <= maximumBytes else {
      throw ModelGenerationFailure(.limitExceeded, "LEAP JSON output exceeds the byte limit.")
    }
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
      object is [String: Any] else { throw malformed() }
    return json
  }

  private static func malformed() -> ModelGenerationFailure {
    .init(.malformedEvent, "LEAP structured output is not one complete JSON object or a single native JSON envelope.")
  }
}
