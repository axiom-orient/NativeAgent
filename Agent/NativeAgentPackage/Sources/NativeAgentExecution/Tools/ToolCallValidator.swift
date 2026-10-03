import Foundation
import NativeAgentDomain

public struct ToolCallValidator: Sendable {
    public init() {}

    public func validate(call: ToolCall, against definition: ToolDefinition) throws {
        let schema = try ToolSchemaDescriptor(schema: definition.inputSchema, path: definition.name)
        try validate(value: call.arguments, schema: schema)
    }

    private func validate(value: JSONValue, schema: ToolSchemaDescriptor) throws {
        try validateType(value: value, schema: schema)
        try validateCommonConstraints(value: value, schema: schema)

        if schema.declaredTypes.contains("object") {
            guard let object = value.objectValue else { return }

            for key in schema.required where object[key] == nil {
                throw AgentError.invalidToolCall("Missing required field \(schema.path).\(key).")
            }

            if schema.additionalProperties == false {
                for key in object.keys where schema.properties[key] == nil {
                    throw AgentError.invalidToolCall("Unexpected field \(schema.path).\(key).")
                }
            }

            for key in schema.properties.keys {
                guard let propertyValue = object[key] else { continue }
                guard let propertySchema = try schema.propertyDescriptor(for: key) else { continue }
                try validate(value: propertyValue, schema: propertySchema)
            }
        }

        if schema.declaredTypes.contains("array") {
            guard let array = value.arrayValue else { return }
            for (index, item) in array.enumerated() {
                guard let itemSchema = try schema.itemDescriptor(at: index) else { continue }
                try validate(value: item, schema: itemSchema)
            }
        }
    }

    private func validateType(value: JSONValue, schema: ToolSchemaDescriptor) throws {
        guard !schema.declaredTypes.isEmpty else {
            return
        }

        let actualType = typeName(of: value)
        let typeMatches = schema.declaredTypes.contains { declaredType in
            matchesType(declaredType: declaredType, actualType: actualType)
        }
        guard typeMatches else {
            throw AgentError.invalidToolCall("Expected \(schema.declaredTypes.joined(separator: " | ")) at \(schema.path), got \(actualType).")
        }
    }

    private func validateCommonConstraints(value: JSONValue, schema: ToolSchemaDescriptor) throws {
        if let enumValues = schema.enumValues, enumValues.contains(value) == false {
            throw AgentError.invalidToolCall("Value at \(schema.path) is not one of the allowed enum values.")
        }

        if let constValue = schema.constValue, constValue != value {
            throw AgentError.invalidToolCall("Value at \(schema.path) does not match the required constant.")
        }

        if let string = value.stringValue {
            // JSON Schema measures string length in Unicode code points, not
            // Swift grapheme clusters (for example, "e\u{301}" has two code points).
            let codePointCount = string.unicodeScalars.count
            if let minLength = schema.minLength, codePointCount < minLength {
                throw AgentError.invalidToolCall("String at \(schema.path) is shorter than \(minLength).")
            }
            if let maxLength = schema.maxLength, codePointCount > maxLength {
                throw AgentError.invalidToolCall("String at \(schema.path) is longer than \(maxLength).")
            }
            if schema.format == "date-time" {
                guard isValidISO8601DateTime(string) else {
                    throw AgentError.invalidToolCall("String at \(schema.path) is not a valid ISO-8601 date-time.")
                }
            }
        }

        if let number = value.numberValue {
            if let minimum = schema.minimum, number < minimum {
                throw AgentError.invalidToolCall("Number at \(schema.path) is smaller than \(minimum).")
            }
            if let maximum = schema.maximum, number > maximum {
                throw AgentError.invalidToolCall("Number at \(schema.path) is larger than \(maximum).")
            }
        }

        if let array = value.arrayValue {
            if let minItems = schema.minItems, array.count < minItems {
                throw AgentError.invalidToolCall("Array at \(schema.path) has fewer than \(minItems) items.")
            }
            if let maxItems = schema.maxItems, array.count > maxItems {
                throw AgentError.invalidToolCall("Array at \(schema.path) has more than \(maxItems) items.")
            }
        }
    }

    private func matchesType(declaredType: String, actualType: String) -> Bool {
        if declaredType == actualType {
            return true
        }
        if declaredType == "number" && actualType == "integer" {
            return true
        }
        return false
    }

    private func typeName(of value: JSONValue) -> String {
        switch value {
        case .string:
            return "string"
        case .integer:
            return "integer"
        case .number:
            return "number"
        case .bool:
            return "boolean"
        case .object:
            return "object"
        case .array:
            return "array"
        case .null:
            return "null"
        }
    }

    private func isValidISO8601DateTime(_ string: String) -> Bool {
        let precise = makePreciseISO8601Formatter()
        let fallback = ISO8601DateFormatter()
        return precise.date(from: string) != nil || fallback.date(from: string) != nil
    }

    private func makePreciseISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
