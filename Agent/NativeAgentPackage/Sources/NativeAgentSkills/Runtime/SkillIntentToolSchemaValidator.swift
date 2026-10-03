import Foundation
import NativeAgentDomain

struct SkillIntentToolSchemaValidator: Sendable {
    func validate(parameters: JSONValue, against definition: ToolDefinition) throws {
        let schema = try SkillIntentToolSchemaDescriptor(schema: definition.inputSchema, path: definition.name)
        try validate(value: parameters, schema: schema)
    }

    private func validate(value: JSONValue, schema: SkillIntentToolSchemaDescriptor) throws {
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

    private func validateType(value: JSONValue, schema: SkillIntentToolSchemaDescriptor) throws {
        guard !schema.declaredTypes.isEmpty else { return }

        let actualType = typeName(of: value)
        let matches = schema.declaredTypes.contains { declaredType in
            declaredType == actualType || (declaredType == "number" && actualType == "integer")
        }
        guard matches else {
            throw AgentError.invalidToolCall(
                "Expected \(schema.declaredTypes.joined(separator: " | ")) at \(schema.path), got \(actualType)."
            )
        }
    }

    private func validateCommonConstraints(value: JSONValue, schema: SkillIntentToolSchemaDescriptor) throws {
        if let enumValues = schema.enumValues, enumValues.contains(value) == false {
            throw AgentError.invalidToolCall("Value at \(schema.path) is not one of the allowed enum values.")
        }

        if let constValue = schema.constValue, constValue != value {
            throw AgentError.invalidToolCall("Value at \(schema.path) does not match the required constant.")
        }

        if let string = value.stringValue {
            let codePointCount = string.unicodeScalars.count
            if let minLength = schema.minLength, codePointCount < minLength {
                throw AgentError.invalidToolCall("String at \(schema.path) is shorter than \(minLength).")
            }
            if let maxLength = schema.maxLength, codePointCount > maxLength {
                throw AgentError.invalidToolCall("String at \(schema.path) is longer than \(maxLength).")
            }
            if schema.format == "date-time", isValidISO8601DateTime(string) == false {
                throw AgentError.invalidToolCall("String at \(schema.path) is not a valid ISO-8601 date-time.")
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

    private func typeName(of value: JSONValue) -> String {
        switch value {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .bool: return "boolean"
        case .object: return "object"
        case .array: return "array"
        case .null: return "null"
        }
    }

    private func isValidISO8601DateTime(_ string: String) -> Bool {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        return precise.date(from: string) != nil || fallback.date(from: string) != nil
    }
}

private struct SkillIntentToolSchemaDescriptor {
    private static let unsupportedValidationKeywords: Set<String> = ["$ref", "allOf", "anyOf", "oneOf"]

    let path: String
    let declaredTypes: [String]
    let properties: [String: JSONValue]
    let required: Set<String>
    let additionalProperties: Bool
    let items: JSONValue?
    let enumValues: [JSONValue]?
    let constValue: JSONValue?
    let minLength: Int?
    let maxLength: Int?
    let format: String?
    let minimum: Double?
    let maximum: Double?
    let minItems: Int?
    let maxItems: Int?

    init(schema: JSONValue, path: String) throws {
        guard let object = schema.objectValue else {
            throw AgentError.invalidToolCall("Schema at \(path) must be an object.")
        }

        let unsupported = object.keys.filter { Self.unsupportedValidationKeywords.contains($0) }.sorted()
        guard unsupported.isEmpty else {
            throw AgentError.invalidToolCall(
                "Unsupported JSON Schema keyword(s) at \(path): \(unsupported.joined(separator: ", "))."
            )
        }

        self.path = path
        if let type = object["type"]?.stringValue {
            self.declaredTypes = [type]
        } else if let types = object["type"]?.arrayValue?.compactMap(\.stringValue) {
            self.declaredTypes = types
        } else {
            self.declaredTypes = []
        }
        self.properties = object["properties"]?.objectValue ?? [:]
        self.required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        self.additionalProperties = object["additionalProperties"]?.boolValue ?? true
        self.items = object["items"]
        self.enumValues = object["enum"]?.arrayValue
        self.constValue = object["const"]
        self.minLength = object["minLength"]?.intValue
        self.maxLength = object["maxLength"]?.intValue
        self.format = object["format"]?.stringValue
        self.minimum = object["minimum"]?.numberValue
        self.maximum = object["maximum"]?.numberValue
        self.minItems = object["minItems"]?.intValue
        self.maxItems = object["maxItems"]?.intValue

        for (key, propertySchema) in self.properties {
            _ = try SkillIntentToolSchemaDescriptor(schema: propertySchema, path: "\(path).\(key)")
        }
        if let items = self.items {
            _ = try SkillIntentToolSchemaDescriptor(schema: items, path: "\(path)[]")
        }
    }

    func propertyDescriptor(for key: String) throws -> SkillIntentToolSchemaDescriptor? {
        guard let propertySchema = properties[key] else { return nil }
        return try SkillIntentToolSchemaDescriptor(schema: propertySchema, path: "\(path).\(key)")
    }

    func itemDescriptor(at index: Int) throws -> SkillIntentToolSchemaDescriptor? {
        guard let items else { return nil }
        return try SkillIntentToolSchemaDescriptor(schema: items, path: "\(path)[\(index)]")
    }
}
