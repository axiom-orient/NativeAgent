import Foundation

extension ToolSchema {
    static func buildString(
        description: String? = nil,
        enum values: [String]? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        format: String? = nil
    ) -> JSONValue {
        var object = baseObject(type: "string", description: description)
        if let values {
            object["enum"] = .array(values.map(JSONValue.string))
        }
        if let minLength {
            object["minLength"] = .integer(Int64(minLength))
        }
        if let maxLength {
            object["maxLength"] = .integer(Int64(maxLength))
        }
        if let format {
            object["format"] = .string(format)
        }
        return .object(object)
    }

    public static func validatedString(
        description: String? = nil,
        enum values: [String]? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        format: String? = nil
    ) throws -> JSONValue {
        try validateLengthBounds(minLength: minLength, maxLength: maxLength)
        return buildString(
            description: description,
            enum: values,
            minLength: minLength,
            maxLength: maxLength,
            format: format
        )
    }

    public static func string(
        description: String? = nil,
        enum values: [String]? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        format: String? = nil
    ) -> JSONValue {
        nonThrowing(label: "ToolSchema.string") {
            try validatedString(
                description: description,
                enum: values,
                minLength: minLength,
                maxLength: maxLength,
                format: format
            )
        }
    }
}
