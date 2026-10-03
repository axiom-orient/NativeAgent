import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution
@testable import NativeAgentTools

@Test
func integerSchemaUsesIntegerBounds() throws {
    let schema = ToolSchema.integer(description: "A whole number.", minimum: 1, maximum: 50)
    let object = try #require(schema.objectValue)

    #expect(object["minimum"] == .integer(1))
    #expect(object["maximum"] == .integer(50))
}

@Test
func validatorAcceptsIntegerForNumberSchema() throws {
    let definition = ToolDefinition(
        name: "math.scale",
        description: "Scale a numeric value.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: [
                "value": ToolSchema.number(description: "A numeric value.")
            ],
            required: ["value"]
        ),
        approvalPolicy: .automatic
    )

    let call = ToolCall(name: "math.scale", arguments: ["value": 3])
    try ToolCallValidator().validate(call: call, against: definition)
}

@Test
func validatorRejectsFractionalNumberForIntegerSchema() throws {
    let definition = ToolDefinition(
        name: "math.count",
        description: "Accept only integers.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: [
                "value": ToolSchema.integer(description: "A whole number.")
            ],
            required: ["value"]
        ),
        approvalPolicy: .automatic
    )

    #expect(throws: AgentError.self) {
        try ToolCallValidator().validate(
            call: ToolCall(name: "math.count", arguments: ["value": .number(3.25)]),
            against: definition
        )
    }
}

@Test
func validatorRejectsInvalidDateTimeString() throws {
    let definition = ToolDefinition(
        name: "calendar.create",
        description: "Create an event.",
        capabilityID: .calendar,
        inputSchema: ToolSchema.object(
            properties: [
                "startDate": ToolSchema.string(format: "date-time")
            ],
            required: ["startDate"]
        ),
        approvalPolicy: .automatic
    )

    #expect(throws: AgentError.self) {
        try ToolCallValidator().validate(
            call: ToolCall(name: "calendar.create", arguments: ["startDate": "2026-04-09 10:00:00"]),
            against: definition
        )
    }
}

@Test
func validatorRejectsUnexpectedFieldWhenAdditionalPropertiesDisabled() throws {
    let definition = ToolDefinition(
        name: "math.scale",
        description: "Scale a numeric value.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: [
                "value": ToolSchema.number(description: "A numeric value.")
            ],
            required: ["value"],
            additionalProperties: false
        ),
        approvalPolicy: .automatic
    )

    #expect(throws: AgentError.self) {
        try ToolCallValidator().validate(
            call: ToolCall(name: "math.scale", arguments: ["value": 3, "extra": true]),
            against: definition
        )
    }
}

@Test
func validatorMeasuresJSONSchemaStringLengthInUnicodeCodePoints() throws {
    let definition = ToolDefinition(
        name: "text.value",
        description: "Accept a short text value.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: ["value": ToolSchema.string(maxLength: 1)],
            required: ["value"]
        ),
        approvalPolicy: .automatic
    )

    #expect(throws: AgentError.self) {
        try ToolCallValidator().validate(
            call: ToolCall(name: "text.value", arguments: ["value": "e\u{301}"]),
            against: definition
        )
    }
}

@Test
func validatorRejectsUnsupportedCompositionInsteadOfSkippingValidation() throws {
    let definition = ToolDefinition(
        name: "value.choice",
        description: "Accept a value matching one of several schemas.",
        capabilityID: .files,
        inputSchema: .object([
            "anyOf": .array([
                .object(["type": "string"]),
                .object(["type": "integer"])
            ])
        ]),
        approvalPolicy: .automatic
    )

    #expect(throws: AgentError.self) {
        try ToolCallValidator().validate(
            call: ToolCall(name: "value.choice", arguments: "accepted"),
            against: definition
        )
    }
}
