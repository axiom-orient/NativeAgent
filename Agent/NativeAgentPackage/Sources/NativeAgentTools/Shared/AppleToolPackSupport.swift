import Foundation
import NativeAgentDomain

func validatePackID(_ value: String) throws {
    guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw AgentError.invalidConfiguration("Tool pack identifier must not be empty.")
    }
}

func requiredObject(
    _ arguments: JSONValue,
    toolName: String
) throws -> [String: JSONValue] {
    guard let object = arguments.objectValue else {
        throw AgentError.invalidToolCall("\(toolName) arguments must be an object.")
    }
    return object
}

func rejectUnknownKeys(
    _ values: [String: JSONValue],
    allowed: Set<String>,
    toolName: String
) throws {
    if let unexpected = values.keys.first(where: { allowed.contains($0) == false }) {
        throw AgentError.invalidToolCall("\(toolName) does not accept \(unexpected).")
    }
}

func optionalISO8601Date(
    _ value: JSONValue?,
    field: String,
    toolName: String
) throws -> Date? {
    guard let value else { return nil }
    guard let text = value.stringValue else {
        throw AgentError.invalidToolCall("\(toolName) \(field) must be an ISO-8601 string.")
    }
    return try parseNativeAgentISO8601Date(text)
}

func optionalBoundedInt(
    _ value: JSONValue?,
    field: String,
    defaultValue: Int,
    range: ClosedRange<Int>,
    toolName: String
) throws -> Int {
    guard let value else { return defaultValue }
    guard let integer = value.intValue, range.contains(integer) else {
        throw AgentError.invalidToolCall(
            "\(toolName) \(field) must be an integer between \(range.lowerBound) and \(range.upperBound)."
        )
    }
    return integer
}

/// Privacy usage strings belong to the app target, not to this package. Check
/// before entering an Apple API that would otherwise terminate the host for a
/// missing declaration.
func requireHostUsageDescription(_ key: String, capability: String) throws {
    try validateHostUsageDescription(
        Bundle.main.object(forInfoDictionaryKey: key),
        key: key,
        capability: capability
    )
}

func validateHostUsageDescription(
    _ rawValue: Any?,
    key: String,
    capability: String
) throws {
    guard let value = rawValue as? String,
          value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw AgentError.invalidConfiguration(
            "\(capability) requires a non-empty \(key) value in the host app Info.plist."
        )
    }
}
