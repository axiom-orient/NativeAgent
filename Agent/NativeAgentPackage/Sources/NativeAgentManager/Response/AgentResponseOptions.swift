import Foundation
import LanguageModelCore

/// Explicit host intent for one user turn. Source text never selects or changes the operation.
public struct AgentResponseOptions: Sendable, Equatable {
  public static let metadataKey = "native-agent.response.options"

  public enum Mode: String, Codable, Sendable {
    case conversation, polish, choose, replace
  }

  public let mode: Mode
  public let language: String?

  public init(mode: Mode = .conversation, language: String? = nil) throws {
    if let language { _ = try AgentResponseLanguage(identifier: language) }
    self.mode = mode
    self.language = language
  }

  public var metadata: [String: JSONValue] {
    var fields: [String: JSONValue] = ["mode": .string(mode.rawValue)]
    if let language { fields["language"] = .string(language) }
    return [Self.metadataKey: .object(fields)]
  }

  static func read(_ metadata: [String: JSONValue]) throws -> Self {
    guard let value = metadata[metadataKey] else { return try Self() }
    guard case .object(let fields) = value,
      Set(fields.keys).isSubset(of: ["mode", "language"]),
      let rawMode = fields["mode"]?.stringValue, let mode = Mode(rawValue: rawMode)
    else { throw AgentResponseError.invalidRequest }
    if let language = fields["language"], language.stringValue == nil {
      throw AgentResponseError.invalidRequest
    }
    return try Self(mode: mode, language: fields["language"]?.stringValue)
  }
}

/// Native editorial envelope. Pass `input` and `metadata` together to run/send/queue/edit.
/// No script, shell, filesystem path, detector or tool execution is required.
public struct AgentWritingRequest: Sendable {
  public let source: String
  public let mode: AgentResponseOptions.Mode
  public let language: String?
  public let input: String
  public let metadata: [String: JSONValue]

  public init(
    source: String,
    mode: AgentResponseOptions.Mode = .polish,
    language: String? = nil,
    candidates: [String] = [],
    target: String? = nil
  ) throws {
    let options = try AgentResponseOptions(mode: mode, language: language)
    let payload = AgentWritingPayload(source: source, candidates: candidates, target: target)
    try payload.validate(mode: mode)
    self.source = source
    self.mode = mode
    self.language = language
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.input = String(decoding: try encoder.encode(payload), as: UTF8.self)
    self.metadata = options.metadata
  }
}

struct AgentWritingPayload: Codable {
  let source: String
  let candidates: [String]
  let target: String?

  func validate(mode: AgentResponseOptions.Mode) throws {
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentResponseError.invalidRequest
    }
    switch mode {
    case .conversation:
      throw AgentResponseError.invalidRequest
    case .polish:
      guard candidates.isEmpty, target == nil else { throw AgentResponseError.invalidRequest }
    case .choose:
      guard (2...8).contains(candidates.count), target == nil,
        candidates.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      else { throw AgentResponseError.invalidRequest }
    case .replace:
      guard candidates.isEmpty, let target, !target.isEmpty,
        source.components(separatedBy: target).count == 2
      else { throw AgentResponseError.invalidRequest }
    }
  }
}
