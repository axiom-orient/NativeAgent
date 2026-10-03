import Foundation
import LanguageModelCore

/// Grammar compilers may fix object-key generation order to schema order.
/// Keep the contract's required-field order, then append optional fields.
enum MLXGrammarSchema {
  static func encode(_ schema: JSONValue) throws -> String {
    try encodeValue(schema, propertyOrder: nil)
  }

  private static func encodeValue(_ value: JSONValue, propertyOrder: [String]?) throws -> String {
    switch value {
    case .object(let object):
      var keys = propertyOrder?.filter { object[$0] != nil } ?? []
      keys += object.keys.filter { !keys.contains($0) }.sorted()
      let required: [String]?
      if case .array(let values) = object["required"] {
        required = values.compactMap { if case .string(let key) = $0 { key } else { nil } }
      } else { required = nil }
      let fields = try keys.map { key in
        let encodedKey = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
        return encodedKey + ":" + (try encodeValue(object[key]!, propertyOrder: key == "properties" ? required : nil))
      }
      return "{" + fields.joined(separator: ",") + "}"
    case .array(let values):
      return "[" + (try values.map { try encodeValue($0, propertyOrder: nil) }).joined(separator: ",") + "]"
    default:
      return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
  }
}
