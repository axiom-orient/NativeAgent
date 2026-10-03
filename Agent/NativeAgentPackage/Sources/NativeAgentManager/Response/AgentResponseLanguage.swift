import Foundation
import NaturalLanguage

public enum AgentResponseLanguage: String, Codable, CaseIterable, Sendable {
  case korean = "ko"
  case english = "en"
  case japanese = "ja"
  case chinese = "zh"
  case spanish = "es"

  var englishName: String {
    switch self {
    case .korean: "Korean"
    case .english: "English"
    case .japanese: "Japanese"
    case .chinese: "Chinese"
    case .spanish: "Spanish"
    }
  }

  /// Accepts language/region/script identifiers; region and script remain in the source and request.
  public init(identifier: String) throws {
    let parts = identifier.replacingOccurrences(of: "_", with: "-").split(
      separator: "-", omittingEmptySubsequences: false)
    guard identifier.utf8.count <= 64, !parts.isEmpty,
      parts.allSatisfy({ part in
        (1...8).contains(part.utf8.count) && part.utf8.allSatisfy {
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        }
      }),
      let language = Self(rawValue: parts[0].lowercased())
    else { throw AgentResponseError.unsupportedLanguage(identifier) }
    self = language
  }

  /// Local, conservative detection. Never constrain hypotheses to supported languages: that
  /// would force unsupported text into a supported bucket. Short/mixed input may remain unknown.
  static func detectIdentifier(_ text: String) -> String? {
    guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 12 else {
      return nil
    }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
    guard let best = hypotheses.first, best.value >= 0.8,
      best.value - (hypotheses.dropFirst().first?.value ?? 0) >= 0.2
    else { return nil }
    return best.key.rawValue
  }
}
