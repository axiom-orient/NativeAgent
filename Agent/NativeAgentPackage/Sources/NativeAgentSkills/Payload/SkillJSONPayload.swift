import Foundation
import NativeAgentDomain

enum SkillJSONPayloadSupport {
    static func anyJSONSchema(description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description + " Pass canonical JSON as a string, for example '{}' or '{\"topic\":\"sales\"}'.")
        ])
    }

    static func objectOrJSONStringSchema(description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description + " Pass a JSON object encoded as a string, for example '{}' or '{\"filename\":\"notes/latest.txt\"}'.")
        ])
    }

    static func canonicalJSONString(
        forField fieldName: String,
        in arguments: JSONValue,
        defaultValue: JSONValue = .object([:]),
        requireJSONObject: Bool = false
    ) throws -> String {
        let fieldValue = arguments.objectValue?[fieldName]
        guard let fieldValue else {
            return try defaultValue.canonicalString()
        }

        if let string = fieldValue.stringValue {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? try defaultValue.canonicalString() : trimmed
        }

        if requireJSONObject, fieldValue.objectValue == nil, fieldValue.isNull == false {
            throw AgentError.invalidToolCall("Field \(fieldName) must be a JSON object or a JSON string containing an object.")
        }

        if fieldValue.isNull {
            return try defaultValue.canonicalString()
        }

        return try fieldValue.canonicalString()
    }
}
