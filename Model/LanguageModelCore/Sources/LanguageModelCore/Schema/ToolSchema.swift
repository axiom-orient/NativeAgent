import Foundation

public enum ToolSchema {
    public enum ValidationError: Error, Equatable, LocalizedError {
        case negativeCount(String)
        case reversedBounds(String)
        case nonFiniteBound(String)

        public var errorDescription: String? {
            switch self {
            case .negativeCount(let message),
                 .reversedBounds(let message),
                 .nonFiniteBound(let message):
                return message
            }
        }
    }

    static func validateLengthBounds(minLength: Int?, maxLength: Int?) throws {
        try validateNonNegativeBounds(
            lower: minLength,
            upper: maxLength,
            lowerError: "ToolSchema.string minLength must be >= 0",
            upperError: "ToolSchema.string maxLength must be >= 0",
            reversedError: "ToolSchema.string minLength must be <= maxLength"
        )
    }

    static func validateIntegerBounds(minimum: Int?, maximum: Int?) throws {
        try validateOrderedBounds(
            lower: minimum,
            upper: maximum,
            reversedError: "ToolSchema.integer minimum must be <= maximum"
        )
    }

    static func validateNumberBounds(minimum: Double?, maximum: Double?) throws {
        if let minimum, !minimum.isFinite {
            throw ValidationError.nonFiniteBound("ToolSchema.number minimum must be finite")
        }
        if let maximum, !maximum.isFinite {
            throw ValidationError.nonFiniteBound("ToolSchema.number maximum must be finite")
        }
        try validateOrderedBounds(
            lower: minimum,
            upper: maximum,
            reversedError: "ToolSchema.number minimum must be <= maximum"
        )
    }

    static func validateItemBounds(minItems: Int?, maxItems: Int?) throws {
        try validateNonNegativeBounds(
            lower: minItems,
            upper: maxItems,
            lowerError: "ToolSchema.array minItems must be >= 0",
            upperError: "ToolSchema.array maxItems must be >= 0",
            reversedError: "ToolSchema.array minItems must be <= maxItems"
        )
    }

    static func baseObject(type: String, description: String?) -> [String: JSONValue] {
        var object: [String: JSONValue] = ["type": .string(type)]
        if let description {
            object["description"] = .string(description)
        }
        return object
    }

    static func nonThrowing<T>(label: String, _ operation: () throws -> T) -> T {
        do {
            return try operation()
        } catch {
            preconditionFailure("Invalid \(label): \(error.localizedDescription)")
        }
    }

    private static func validateNonNegativeBounds(
        lower: Int?,
        upper: Int?,
        lowerError: String,
        upperError: String,
        reversedError: String
    ) throws {
        if let lower, lower < 0 {
            throw ValidationError.negativeCount(lowerError)
        }
        if let upper, upper < 0 {
            throw ValidationError.negativeCount(upperError)
        }
        try validateOrderedBounds(lower: lower, upper: upper, reversedError: reversedError)
    }

    private static func validateOrderedBounds<T: Comparable>(
        lower: T?,
        upper: T?,
        reversedError: String
    ) throws {
        if let lower, let upper, lower > upper {
            throw ValidationError.reversedBounds(reversedError)
        }
    }

}
