import Foundation
import Testing

@testable import LanguageModelCore

@Test
func canonicalStringSortsKeys() throws {
    let value: JSONValue = [
        "b": 2,
        "a": 1,
    ]

    #expect(try value.canonicalString() == #"{"a":1,"b":2}"#)
}

@Test
func jsonValueRoundTripsThroughCodable() throws {
    let original: JSONValue = [
        "string": "hello",
        "array": [.bool(true), .null],
        "number": 42,
    ]

    let data = try JSONEncoder.nativeAgent().encode(original)
    let decoded = try JSONDecoder.nativeAgent().decode(JSONValue.self, from: data)
    #expect(decoded == original)
}

@Test
func objectSubscriptIsPublicContractAndFailsClosedForNonObjects() {
    let object: JSONValue = ["name": "NativeAgent"]

    #expect(object["name"] == .string("NativeAgent"))
    #expect(object["missing"] == nil)
    #expect(JSONValue.string("NativeAgent")["name"] == nil)
}

@Test
func jsonValueFromAnyFailsForUnsupportedArrayElements() {
    final class Unsupported {}
    let converted = JSONValue.from(any: ["ok", Unsupported()])
    #expect(converted == nil)
}

@Test
func largeIntegerRoundTripsWithoutPrecisionLoss() throws {
    let input = #"{"id":9007199254740993}"#
    let value = try JSONDecoder.nativeAgent().decode(JSONValue.self, from: Data(input.utf8))

    #expect(value.objectValue?["id"] == .integer(9_007_199_254_740_993))

    let reencoded = try JSONEncoder.nativeAgent().encode(value)
    let output = try #require(String(data: reencoded, encoding: .utf8))
    #expect(output == input)
}

@Test
func integerAndNumberAccessorsPreserveSemantics() {
    let integer = JSONValue.integer(42)
    let number = JSONValue.number(42.5)
    let exactNumber = JSONValue.number(42.0)

    #expect(integer.numberValue == 42)
    #expect(integer.intValue == 42)
    #expect(number.numberValue == 42.5)
    #expect(number.intValue == nil)
    #expect(exactNumber.intValue == 42)
}

@Test
func canonicalCharacterCountMatchesCanonicalStringForRepresentativeValues() throws {
    let combiningAccent = "cafe\u{301}"
    let samples: [JSONValue] = [
        .null,
        .bool(true),
        .integer(42),
        .number(1.5),
        .number(-0.0),
        .string("plain"),
        .string("quote \" slash / backslash \\ and tab \t"),
        .string("emoji 😀 \(combiningAccent)"),
        .array([.string("a"), .integer(2), .object(["x": .bool(false)])]),
        .object([
            "b": .number(3.14),
            "a": .string("line\nfeed"),
            "nested": .array([.string("z"), .string("y")]),
        ]),
    ]

    for sample in samples {
        let canonical = try sample.canonicalString()
        #expect(try sample.canonicalCharacterCount() == canonical.count)
        #expect(try sample.canonicalUTF8ByteCount() == canonical.utf8.count)
    }
}

@Test
func canonicalCharacterCountMatchesCanonicalStringForNumberRepresentations() throws {
    let samples: [(JSONValue, String)] = [
        (.number(-0.0), "-0"),
        (.number(0.0), "0"),
        (.number(1.0), "1"),
        (.number(1.5), "1.5"),
        (.number(1e-6), "1e-06"),
        (.number(1e20), "1e+20"),
        (.number(9_007_199_254_740_992.0), "9007199254740992"),
    ]

    for (sample, expectedCanonical) in samples {
        #expect(try sample.canonicalString() == expectedCanonical)
        #expect(try sample.canonicalCharacterCount() == expectedCanonical.count)
        #expect(try sample.canonicalUTF8ByteCount() == expectedCanonical.utf8.count)
    }
}

@Test
func canonicalJSONStringThrowsOnNonFiniteNumbers() {
    let value = JSONValue.number(.nan)
    #expect(throws: (any Error).self) {
        _ = try value.canonicalJSONString()
    }
}

@Test
func nonFiniteNumbersAreRejectedWithoutIdentityCollision() {
    let invalid = JSONValue.number(.nan)
    let validNull = JSONValue.null

    #expect(throws: (any Error).self) { _ = try invalid.canonicalString() }
    #expect(throws: (any Error).self) { _ = try invalid.canonicalCharacterCount() }
    #expect(throws: (any Error).self) { _ = try invalid.canonicalUTF8ByteCount() }
    #expect(invalid.displayString().hasPrefix("<invalid JSON:"))

    let invalidCall = ToolCall(name: "lookup", arguments: invalid)
    let nullCall = ToolCall(name: "lookup", arguments: validNull)
    #expect(invalidCall.id != nullCall.id)
}

@Test
func toolSchemaValidationRejectsReversedBounds() {
    #expect(throws: (any Error).self) {
        try ToolSchema.validateLengthBounds(minLength: 5, maxLength: 1)
    }
    #expect(throws: (any Error).self) {
        try ToolSchema.validateIntegerBounds(minimum: 2, maximum: 1)
    }
    #expect(throws: (any Error).self) {
        try ToolSchema.validateNumberBounds(minimum: 2, maximum: 1)
    }
    #expect(throws: (any Error).self) {
        try ToolSchema.validateItemBounds(minItems: 3, maxItems: 1)
    }
}

@Test
func validatedToolSchemaFactoriesSurfaceTypedValidationErrors() {
    let cases: [(String, () throws -> JSONValue, ToolSchema.ValidationError)] = [
        (
            "string negative minimum length",
            { try ToolSchema.validatedString(minLength: -1) },
            .negativeCount("ToolSchema.string minLength must be >= 0")
        ),
        (
            "string negative maximum length",
            { try ToolSchema.validatedString(maxLength: -1) },
            .negativeCount("ToolSchema.string maxLength must be >= 0")
        ),
        (
            "string reversed bounds",
            { try ToolSchema.validatedString(minLength: 5, maxLength: 1) },
            .reversedBounds("ToolSchema.string minLength must be <= maxLength")
        ),
        (
            "integer reversed bounds",
            { try ToolSchema.validatedInteger(minimum: 2, maximum: 1) },
            .reversedBounds("ToolSchema.integer minimum must be <= maximum")
        ),
        (
            "number non-finite minimum",
            { try ToolSchema.validatedNumber(minimum: .nan) },
            .nonFiniteBound("ToolSchema.number minimum must be finite")
        ),
        (
            "number non-finite maximum",
            { try ToolSchema.validatedNumber(maximum: .infinity) },
            .nonFiniteBound("ToolSchema.number maximum must be finite")
        ),
        (
            "array negative minimum items",
            { try ToolSchema.validatedArray(items: ToolSchema.boolean(), minItems: -1) },
            .negativeCount("ToolSchema.array minItems must be >= 0")
        ),
        (
            "array negative maximum items",
            { try ToolSchema.validatedArray(items: ToolSchema.boolean(), maxItems: -1) },
            .negativeCount("ToolSchema.array maxItems must be >= 0")
        ),
        (
            "array reversed bounds",
            { try ToolSchema.validatedArray(items: ToolSchema.boolean(), minItems: 2, maxItems: 1) },
            .reversedBounds("ToolSchema.array minItems must be <= maxItems")
        ),
    ]

    for (label, makeSchema, expectedError) in cases {
        do {
            _ = try makeSchema()
            Issue.record("Expected \(label) to throw")
        } catch let error as ToolSchema.ValidationError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Unexpected error for \(label): \(error)")
        }
    }
}

@Test
func nonthrowingToolSchemaFactoriesPreserveValidatedBounds() throws {
    let stringSchema = try #require(
        ToolSchema.string(
            description: "Name",
            enum: ["alpha"],
            minLength: 1,
            maxLength: 4,
            format: "uri"
        ).objectValue
    )
    #expect(stringSchema["type"] == .string("string"))
    #expect(stringSchema["description"] == .string("Name"))
    #expect(stringSchema["enum"] == .array([.string("alpha")]))
    #expect(stringSchema["minLength"] == .integer(1))
    #expect(stringSchema["maxLength"] == .integer(4))
    #expect(stringSchema["format"] == .string("uri"))

    let integerSchema = try #require(
        ToolSchema.integer(description: "Count", minimum: 1, maximum: 5).objectValue
    )
    #expect(integerSchema["minimum"] == .integer(1))
    #expect(integerSchema["maximum"] == .integer(5))

    let numberSchema = try #require(
        ToolSchema.number(description: "Ratio", minimum: 0, maximum: 1.5).objectValue
    )
    #expect(numberSchema["minimum"] == .number(0))
    #expect(numberSchema["maximum"] == .number(1.5))

    let itemSchema = ToolSchema.string(description: "Item", minLength: 1)
    let arraySchema = try #require(
        ToolSchema.array(
            items: itemSchema,
            description: "Values",
            minItems: 1,
            maxItems: 3
        ).objectValue
    )
    #expect(arraySchema["items"] == itemSchema)
    #expect(arraySchema["minItems"] == .integer(1))
    #expect(arraySchema["maxItems"] == .integer(3))
}

@Test
func coreDefaultIdentifiersAreDeterministicAndDoNotUseWallClockOrRandomUUID() {
    let firstCall = ToolCall(name: "files.list", arguments: ["path": "notes"])
    let secondCall = ToolCall(name: "files.list", arguments: ["path": "notes"])
    #expect(firstCall.id == secondCall.id)
    #expect(firstCall.id.hasPrefix("toolcall-"))

    let firstMessage = AgentMessage(role: .assistant, content: "same")
    let secondMessage = AgentMessage(role: .assistant, content: "same")
    #expect(firstMessage.id == secondMessage.id)
    #expect(firstMessage.createdAt == Date(timeIntervalSince1970: 0))
}

@Test
func modelVisibleToolContentUsesDurableStructuredOutput() throws {
    let message = AgentMessage(
        role: .tool,
        content: "hello",
        toolCallID: "call-1",
        toolName: "files.readText",
        metadata: [
            "output": .object(["content": .string("hello"), "sha256": .string("abc123")]),
            "isError": .bool(false),
            "source": .string("filesystem")
        ]
    )

    #expect(message.content == "hello")
    let visible = try message.modelVisibleContent()
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(visible.utf8)) as? [String: Any]
    )
    let output = try #require(object["output"] as? [String: Any])
    let metadata = try #require(object["metadata"] as? [String: Any])
    #expect(output["sha256"] as? String == "abc123")
    #expect(object["isError"] as? Bool == false)
    #expect(metadata["source"] as? String == "filesystem")
}

@Test
func modelVisibleToolErrorPreservesMachineFailureSemantics() throws {
    let message = AgentMessage(
        role: .tool,
        content: "Calendar event changed before mutation.",
        toolCallID: "call-2",
        toolName: "calendar.updateEvent",
        metadata: [
            "isError": .bool(true),
            "errorCode": .string("conflict")
        ]
    )

    #expect(message.content == "Calendar event changed before mutation.")
    let visible = try message.modelVisibleContent()
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(visible.utf8)) as? [String: Any]
    )
    let output = try #require(object["output"] as? [String: Any])
    let metadata = try #require(object["metadata"] as? [String: Any])
    #expect(output["content"] as? String == message.content)
    #expect(object["isError"] as? Bool == true)
    #expect(metadata["errorCode"] as? String == "conflict")
}
