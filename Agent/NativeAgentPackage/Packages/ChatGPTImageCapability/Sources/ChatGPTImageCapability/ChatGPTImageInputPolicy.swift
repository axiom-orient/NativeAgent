import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
import LanguageModelCore

/// Shared by direct tools, catalog tools and skill intents. Schema admission is not assumed.
enum ChatGPTImageInputPolicy {
  static let commonKeys: Set<String> = ["prompt", "background", "quality", "size", "output_filename"]

  static func object(_ value: JSONValue, allowing keys: Set<String>) throws -> [String: JSONValue] {
    guard let object = value.objectValue, Set(object.keys).isSubset(of: keys) else {
      throw AgentError.invalidToolCall("Image arguments must be an object containing only declared fields")
    }
    return object
  }

  static func string(_ key: String, in object: [String: JSONValue], required: Bool = false) throws -> String? {
    guard let value = object[key] else {
      if required { throw AgentError.invalidToolCall("Missing image field: \(key)") }
      return nil
    }
    guard let text = value.stringValue else {
      throw AgentError.invalidToolCall("Image field \(key) must be a string")
    }
    return text
  }

  static func prompt(_ text: String) throws -> String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !normalized.contains("\0"),
      normalized.utf8.count <= ChatGPTImageClient.maximumPromptUTF8Bytes else {
      throw AgentError.invalidToolCall("Image prompt must be nonempty and fit the provider UTF-8 byte limit")
    }
    return normalized
  }

  static func size(_ text: String) throws -> String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "auto" { return normalized }
    let parts = normalized.split(separator: "x", omittingEmptySubsequences: false)
    guard normalized.utf8.count <= 64, parts.count == 2,
      parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
      let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
      throw AgentError.invalidToolCall("Image size must be auto or positive WIDTHxHEIGHT")
    }
    return "\(width)x\(height)"
  }

  static func filename(_ value: String, maximumCharacters: Int) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= maximumCharacters,
      normalized.utf8.count <= 255, !normalized.contains("/"), !normalized.contains("\\"),
      !normalized.contains(".."),
      !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw AgentError.invalidToolCall("Image filename must be a bounded plain filename without control characters")
    }
    return normalized
  }
}

