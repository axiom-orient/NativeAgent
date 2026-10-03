import Foundation
import XCTest
import LanguageModelCore
@testable import MLXProvider

final class MLXStructuredOutputTests: XCTestCase {
  private let schema: JSONValue = .object([
    "type": "object", "properties": .object([
      "count": .object(["type": "integer", "minimum": 1, "maximum": 3]),
      "label": .object(["type": "string", "enum": .array(["ready"])])
    ]), "required": .array(["count", "label"]), "additionalProperties": false
  ])

  func testRejectsValidJSONThatViolatesSchema() throws {
    try MLXOutputSchema.validateSchema(schema)
    try MLXOutputSchema.validateOutput(#"{"count":2,"label":"ready"}"#, schema: schema)
    for invalid in [#"{"count":4,"label":"ready"}"#, #"{"count":2}"#,
                    #"{"count":2,"label":"wrong"}"#, #"{"count":true,"label":"ready"}"#,
                    #"{"count":2,"label":"ready","extra":1}"#, #"{"count":1.5,"label":"ready"}"#] {
      XCTAssertThrowsError(try MLXOutputSchema.validateOutput(invalid, schema: schema))
    }
  }

  func testUnsupportedSchemaFailsClosed() {
    let unsupported: JSONValue = .object(["type": "string", "pattern": "^a$"])
    XCTAssertThrowsError(try MLXOutputSchema.validateSchema(unsupported))
  }

  func testIntegerBoundsDoNotRoundThroughDouble() throws {
    let large: JSONValue = .object(["type": "object", "properties": .object([
      "n": .object(["type": "integer", "maximum": .integer(9_007_199_254_740_992)])])])
    try MLXOutputSchema.validateSchema(large)
    XCTAssertThrowsError(try MLXOutputSchema.validateOutput(#"{"n":9007199254740993}"#, schema: large))
  }
  func testUnrepresentableBoundsAndLossyNumbersFailClosed() throws {
    let huge: JSONValue = .object(["type": "number", "minimum": .number(1e200)])
    XCTAssertThrowsError(try MLXOutputSchema.validateSchema(huge))
    let precise: JSONValue = .object(["type": "object", "properties": .object([
      "n": .object(["type": "integer", "const": 1])])])
    XCTAssertThrowsError(try MLXOutputSchema.validateOutput(#"{"n":1.0000000000000001}"#, schema: precise))
    try MLXOutputSchema.validateOutput(#"{"n":1.0}"#, schema: precise)
  }
  func testNullableNestedTypesStayStrict() throws {
    let schema: JSONValue = .object(["type": "object", "properties": .object([
      "value": .object(["type": .array(["string", "null"]), "maxLength": 3])
    ]), "required": .array(["value"]), "additionalProperties": false])
    try MLXOutputSchema.validateSchema(schema)
    try MLXOutputSchema.validateOutput(#"{"value":null}"#, schema: schema)
    try MLXOutputSchema.validateOutput(#"{"value":"yes"}"#, schema: schema)
    XCTAssertThrowsError(try MLXOutputSchema.validateOutput(#"{"value":1}"#, schema: schema))
    XCTAssertThrowsError(try MLXOutputSchema.validateOutput(#"{"value":"long"}"#, schema: schema))
  }
}
