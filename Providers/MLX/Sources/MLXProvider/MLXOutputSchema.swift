import Foundation
import LanguageModelCore

/// A fail-closed schema subset. Unsupported constraints are rejected before
/// generation; a JSON-shaped response is never enough to claim schema compliance.
enum MLXOutputSchema {
  private static let types: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]
  private static let keywords: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum", "const", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "description", "title"]

  static func validateSchema(_ schema: JSONValue) throws {
    guard let object = schema.objectValue,
          Set(object.keys).isSubset(of: keywords),
          let rawType = object["type"] else {
      throw ModelGenerationFailure(.invalidRequest, "MLX requires an explicit type and supported JSON schema constraints.")
    }
    let declared: [String]
    if let type = rawType.stringValue { declared = [type] }
    else if let array = rawType.arrayValue, array.allSatisfy({ $0.stringValue != nil }) {
      declared = array.compactMap(\.stringValue)
    } else { throw invalidSchema() }
    guard !declared.isEmpty, Set(declared).count == declared.count,
          Set(declared).isSubset(of: types) else { throw invalidSchema() }
    for key in ["title", "description"] where object[key] != nil {
      guard object[key]?.stringValue != nil else { throw invalidSchema() }
    }
    if let properties = object["properties"] {
      guard declared.contains("object"), let values = properties.objectValue else { throw invalidSchema() }
      for value in values.values { try validateSchema(value) }
    }
    if let required = object["required"] {
      guard declared.contains("object"), let values = required.arrayValue,
            values.allSatisfy({ $0.stringValue != nil }),
            Set(values.compactMap(\.stringValue)).count == values.count else { throw invalidSchema() }
    }
    if let additional = object["additionalProperties"] {
      guard declared.contains("object"), additional.boolValue != nil else { throw invalidSchema() }
    }
    if let items = object["items"] {
      guard declared.contains("array") else { throw invalidSchema() }
      try validateSchema(items)
    }
    if let values = object["enum"] {
      guard let array = values.arrayValue, !array.isEmpty else { throw invalidSchema() }
    }
    for key in ["minimum", "maximum"] where object[key] != nil {
      guard declared.contains("number") || declared.contains("integer"), object[key].flatMap(decimal) != nil else { throw invalidSchema() }
    }
    for (kind, keys) in [("string", ["minLength", "maxLength"]), ("array", ["minItems", "maxItems"])] {
      for key in keys where object[key] != nil {
        guard declared.contains(kind), let value = object[key]?.numberValue,
              value.isFinite, value >= 0, value.rounded() == value else { throw invalidSchema() }
      }
    }
  }

  static func validateOutput(_ text: String, schema: JSONValue) throws {
    let value: JSONValue
    do { value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    catch { throw ModelGenerationFailure(.malformedEvent, "MLX structured output is not valid JSON.") }
    try validateNumberTokens(text)
    guard value.objectValue != nil, matches(value, schema: schema) else {
      throw ModelGenerationFailure(.malformedEvent, "MLX output violates the requested JSON schema.")
    }
  }

  private static func matches(_ value: JSONValue, schema: JSONValue) -> Bool {
    guard let s = schema.objectValue else { return false }
    if let alternatives = s["type"]?.arrayValue {
      return alternatives.contains { type in
        var branch = s
        branch["type"] = type
        return matches(value, schema: .object(branch))
      }
    }
    guard let type = s["type"]?.stringValue else { return false }
    if let constant = s["const"], !equal(value, constant) { return false }
    if let values = s["enum"]?.arrayValue, !values.contains(where: { equal(value, $0) }) { return false }
    switch type {
    case "object":
      guard let object = value.objectValue else { return false }
      let properties = s["properties"]?.objectValue ?? [:]
      for key in s["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil { return false }
      if s["additionalProperties"]?.boolValue == false && !Set(object.keys).isSubset(of: Set(properties.keys)) { return false }
      return object.allSatisfy { key, child in properties[key].map { matches(child, schema: $0) } ?? true }
    case "array":
      guard let array = value.arrayValue,
            bounded(Double(array.count), lower: s["minItems"], upper: s["maxItems"]) else { return false }
      return s["items"].map { item in array.allSatisfy { matches($0, schema: item) } } ?? true
    case "string":
      guard let text = value.stringValue else { return false }
      return bounded(Double(text.unicodeScalars.count), lower: s["minLength"], upper: s["maxLength"])
    case "number", "integer":
      guard let number = value.numberValue, number.isFinite else { return false }
      guard type != "integer" || number.rounded() == number,
            let exact = decimal(value) else { return false }
      if let lower = s["minimum"] {
        guard let bound = decimal(lower), exact >= bound else { return false }
      }
      if let upper = s["maximum"] {
        guard let bound = decimal(upper), exact <= bound else { return false }
      }
      return true
    case "boolean": return value.boolValue != nil
    case "null": return value == .null
    default: return false
    }
  }

  private static func equal(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
    if let a = decimal(lhs), let b = decimal(rhs) { return a == b }
    if let a = lhs.arrayValue, let b = rhs.arrayValue {
      return a.count == b.count && zip(a, b).allSatisfy(equal)
    }
    if let a = lhs.objectValue, let b = rhs.objectValue {
      return a.count == b.count && a.allSatisfy { key, value in b[key].map { equal(value, $0) } ?? false }
    }
    return lhs == rhs
  }

  // JSONValue stores integers exactly and fractional numbers as Double.
  // Reject numeric tokens that would lose decimal digits before schema checks.
  // Strings are skipped, including escaped quotes; syntax was already decoded.
  private static func validateNumberTokens(_ text: String) throws {
    let bytes = Array(text.utf8)
    var index = 0
    var quoted = false
    while index < bytes.count {
      let byte = bytes[index]
      if quoted {
        if byte == 92 { index += 2; continue }
        if byte == 34 { quoted = false }
        index += 1
        continue
      }
      if byte == 34 { quoted = true; index += 1; continue }
      guard byte == 45 || (48...57).contains(byte) else { index += 1; continue }
      let start = index
      while index < bytes.count && ![UInt8(44), 93, 125, 32, 9, 10, 13].contains(bytes[index]) { index += 1 }
      let token = String(decoding: bytes[start..<index], as: UTF8.self)
      if Int64(token) != nil { continue }
      let digits = token.prefix { $0 != "e" && $0 != "E" }.filter { $0.isNumber }.count
      guard digits <= 38,
            let exact = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")),
            let floating = Double(token), floating.isFinite,
            let roundTrip = Decimal(string: String(floating), locale: Locale(identifier: "en_US_POSIX")),
            exact == roundTrip else {
        throw ModelGenerationFailure(.malformedEvent, "MLX JSON number exceeds lossless supported precision.")
      }
    }
  }

  private static func decimal(_ value: JSONValue) -> Decimal? {
    switch value {
    case .integer(let value): Decimal(value)
    case .number(let value): value.isFinite ? Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) : nil
    default: nil
    }
  }

  private static func bounded(_ value: Double, lower: JSONValue?, upper: JSONValue?) -> Bool {
    (lower?.numberValue.map { value >= $0 } ?? true) && (upper?.numberValue.map { value <= $0 } ?? true)
  }

  private static func invalidSchema() -> ModelGenerationFailure {
    ModelGenerationFailure(.invalidRequest, "MLX JSON schema constraint is invalid or unsupported.")
  }
}
