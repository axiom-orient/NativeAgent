import Foundation

extension ToolSchema {
    public static func validatedArray(
        items: JSONValue,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) throws -> JSONValue {
        try validateItemBounds(minItems: minItems, maxItems: maxItems)
        return buildArray(
            items: items,
            description: description,
            minItems: minItems,
            maxItems: maxItems
        )
    }

    public static func array(
        items: JSONValue,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> JSONValue {
        nonThrowing(label: "ToolSchema.array") {
            try validatedArray(
                items: items,
                description: description,
                minItems: minItems,
                maxItems: maxItems
            )
        }
    }

    static func buildArray(
        items: JSONValue,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> JSONValue {
        var object = baseObject(type: "array", description: description)
        object["items"] = items
        if let minItems {
            object["minItems"] = .integer(Int64(minItems))
        }
        if let maxItems {
            object["maxItems"] = .integer(Int64(maxItems))
        }
        return .object(object)
    }

    public static func object(
        properties: [String: JSONValue],
        required: [String] = [],
        additionalProperties: Bool = false,
        description: String? = nil
    ) -> JSONValue {
        var object = baseObject(type: "object", description: description)
        object["properties"] = .object(properties)
        object["required"] = .array(required.map(JSONValue.string))
        object["additionalProperties"] = .bool(additionalProperties)
        return .object(object)
    }
}
