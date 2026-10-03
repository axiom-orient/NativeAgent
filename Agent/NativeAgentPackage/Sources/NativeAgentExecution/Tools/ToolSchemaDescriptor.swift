import Foundation
import NativeAgentDomain

struct ToolSchemaDescriptor {
    private static let unsupportedValidationKeywords: Set<String> = [
        "$ref",
        "allOf",
        "anyOf",
        "oneOf",
    ]

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
        guard let schemaObject = schema.objectValue else {
            throw AgentError.invalidToolCall("Schema at \(path) must be an object.")
        }

        let unsupportedKeywords = schemaObject.keys
            .filter { Self.unsupportedValidationKeywords.contains($0) }
            .sorted()
        guard unsupportedKeywords.isEmpty else {
            throw AgentError.invalidToolCall(
                "Unsupported JSON Schema keyword(s) at \(path): \(unsupportedKeywords.joined(separator: ", "))."
            )
        }

        self.path = path
        self.declaredTypes = ToolSchemaDescriptor.extractTypes(from: schemaObject)
        self.properties = schemaObject["properties"]?.objectValue ?? [:]
        self.required = Set(schemaObject["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        self.additionalProperties = schemaObject["additionalProperties"]?.boolValue ?? true
        self.items = schemaObject["items"]
        self.enumValues = schemaObject["enum"]?.arrayValue
        self.constValue = schemaObject["const"]
        self.minLength = schemaObject["minLength"]?.intValue
        self.maxLength = schemaObject["maxLength"]?.intValue
        self.format = schemaObject["format"]?.stringValue
        self.minimum = schemaObject["minimum"]?.numberValue
        self.maximum = schemaObject["maximum"]?.numberValue
        self.minItems = schemaObject["minItems"]?.intValue
        self.maxItems = schemaObject["maxItems"]?.intValue

        // Validate nested schemas eagerly so an unsupported keyword cannot be
        // hidden in a property or array item and discovered only after a
        // model has already emitted a call.
        if self.properties.isEmpty == false {
            let properties = self.properties
            for (key, propertySchema) in properties {
                _ = try ToolSchemaDescriptor(schema: propertySchema, path: "\(path).\(key)")
            }
        }
        if let items = self.items {
            _ = try ToolSchemaDescriptor(schema: items, path: "\(path)[]")
        }
    }

    func propertyDescriptor(for key: String) throws -> ToolSchemaDescriptor? {
        guard let propertySchema = properties[key] else {
            return nil
        }
        return try ToolSchemaDescriptor(schema: propertySchema, path: "\(path).\(key)")
    }

    func itemDescriptor(at index: Int) throws -> ToolSchemaDescriptor? {
        guard let items else {
            return nil
        }
        return try ToolSchemaDescriptor(schema: items, path: "\(path)[\(index)]")
    }

    private static func extractTypes(from schemaObject: [String: JSONValue]) -> [String] {
        if let type = schemaObject["type"]?.stringValue {
            return [type]
        }
        if let typeArray = schemaObject["type"]?.arrayValue?.compactMap(\.stringValue) {
            return typeArray
        }
        return []
    }
}
