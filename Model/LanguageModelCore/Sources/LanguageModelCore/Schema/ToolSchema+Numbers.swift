import Foundation

extension ToolSchema {
    static func buildInteger(
        description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONValue {
        var object = baseObject(type: "integer", description: description)
        if let minimum {
            object["minimum"] = .integer(Int64(minimum))
        }
        if let maximum {
            object["maximum"] = .integer(Int64(maximum))
        }
        return .object(object)
    }

    public static func validatedInteger(
        description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) throws -> JSONValue {
        try validateIntegerBounds(minimum: minimum, maximum: maximum)
        return buildInteger(description: description, minimum: minimum, maximum: maximum)
    }

    public static func integer(
        description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONValue {
        nonThrowing(label: "ToolSchema.integer") {
            try validatedInteger(description: description, minimum: minimum, maximum: maximum)
        }
    }

    static func buildNumber(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONValue {
        var object = baseObject(type: "number", description: description)
        if let minimum {
            object["minimum"] = .number(minimum)
        }
        if let maximum {
            object["maximum"] = .number(maximum)
        }
        return .object(object)
    }

    public static func validatedNumber(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) throws -> JSONValue {
        try validateNumberBounds(minimum: minimum, maximum: maximum)
        return buildNumber(description: description, minimum: minimum, maximum: maximum)
    }

    public static func number(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONValue {
        nonThrowing(label: "ToolSchema.number") {
            try validatedNumber(description: description, minimum: minimum, maximum: maximum)
        }
    }

    public static func boolean(description: String? = nil) -> JSONValue {
        .object(baseObject(type: "boolean", description: description))
    }
}
