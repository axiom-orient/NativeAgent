import Foundation
import Testing

@testable import LanguageModelCore

@Suite("JSON integer conversion boundaries")
struct JSONNumericBoundaryTests {
  @Test func roundedUpperIntegerBoundReturnsNilWithoutTrapping() {
    #expect(JSONValue.number(Double(Int.max)).intValue == nil)
  }

  @Test func exactIntegerConversionPreservesRepresentableValues() {
    for value in [Int.min, -1, 0, 1, 42] {
      #expect(JSONValue.number(Double(value)).intValue == value)
    }
    #expect(JSONValue.integer(Int64.max).intValue == Int.max)
    #expect(
      JSONValue.number(Double(Int.max).nextDown).intValue == Int(exactly: Double(Int.max).nextDown))
  }

  @Test func invalidNumericValuesNeverProduceAnInteger() {
    for value in [
      Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
      Double(Int.min).nextDown, Double(Int.max).nextUp, 1.5, -1.5,
    ] {
      #expect(JSONValue.number(value).intValue == nil)
    }
  }

  @Test func foundationNumbersPreserveNumericIdentity() {
    #expect(JSONValue.from(any: NSNumber(value: 0)) == .integer(0))
    #expect(JSONValue.from(any: NSNumber(value: 1)) == .integer(1))
    #expect(JSONValue.from(any: NSNumber(value: true)) == .bool(true))
    #expect(JSONValue.from(any: NSNumber(value: Int64.max)) == .integer(Int64.max))
    #expect(JSONValue.from(any: NSNumber(value: UInt64.max)) == nil)
    #expect(JSONValue.from(any: Double(1.5)) == .number(1.5))
  }

  @Test func nestedFoundationInputKeepsBooleansSeparateFromNumbers() throws {
    let input = try JSONSerialization.jsonObject(
      with: Data(#"{"zero":0,"one":1,"flag":true}"#.utf8))
    #expect(
      JSONValue.from(any: input)
        == .object([
          "zero": .integer(0), "one": .integer(1), "flag": .bool(true),
        ]))
    #expect(JSONValue.from(any: true) == .bool(true))
    #expect(JSONValue.from(any: false) == .bool(false))
  }

  @Test func decodedUpperBoundaryUsesTheSameSafeAccessor() throws {
    let input = Data("9223372036854775808".utf8)
    let value = try JSONDecoder().decode(JSONValue.self, from: input)
    #expect(value.intValue == nil)
  }
}
