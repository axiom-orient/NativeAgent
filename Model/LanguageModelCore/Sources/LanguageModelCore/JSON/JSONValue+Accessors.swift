import Foundation

public enum JSONValueError: Error, Sendable, Equatable, LocalizedError {
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            "Canonical JSON encoding produced invalid UTF-8."
        }
    }
}

extension JSONValue {
    /// Returns an object member when this value is a JSON object.
    /// Non-object values return `nil` instead of inventing a fallback value.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.nativeAgent().encode(value)
        return try JSONDecoder.nativeAgent().decode(JSONValue.self, from: data)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder.nativeAgent().encode(self)
        return try JSONDecoder.nativeAgent().decode(T.self, from: data)
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        switch self {
        case .integer(let value):
            return Double(value)
        case .number(let value):
            return value
        default:
            return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value):
            return Int(exactly: value)
        case .number(let value):
            // Double(Int.max) rounds up on 64-bit platforms. Comparing against
            // that rounded bound before Int(value) can admit a trapping value.
            return Int(exactly: value)
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Encodes valid JSON deterministically with sorted object keys.
    /// Invalid values such as non-finite numbers are rejected.
    public func canonicalString(prettyPrinted: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JSONValueError.invalidUTF8
        }
        return string
    }

    public func canonicalJSONString(prettyPrinted: Bool = false) throws -> String {
        try canonicalString(prettyPrinted: prettyPrinted)
    }

    /// Human-readable diagnostics only. Never use this value for identity,
    /// persistence, hashing, or provider transport.
    public func displayString(prettyPrinted: Bool = false) -> String {
        do {
            return try canonicalString(prettyPrinted: prettyPrinted)
        } catch {
            return "<invalid JSON: \(error.localizedDescription)>"
        }
    }

    /// Total deterministic representation for in-memory identity and loop
    /// detection. Invalid numeric values remain distinct from JSON null.
    /// The iterative encoder avoids recursion proportional to untrusted JSON depth.
    public func stableIdentityString() -> String {
        enum WorkItem {
            case value(JSONValue)
            case text(String)
        }

        var output = ""
        var stack: [WorkItem] = [.value(self)]

        while let item = stack.popLast() {
            switch item {
            case .text(let text):
                output.append(text)

            case .value(let value):
                switch value {
                case .null:
                    output.append("n;")
                case .bool(let value):
                    output.append(value ? "b1;" : "b0;")
                case .integer(let value):
                    output.append("i")
                    output.append(String(value))
                    output.append(";")
                case .number(let value):
                    output.append("d")
                    output.append(String(value.bitPattern, radix: 16))
                    output.append(";")
                case .string(let value):
                    output.append("s")
                    output.append(String(value.utf8.count))
                    output.append(":")
                    output.append(value)
                    output.append(";")
                case .array(let values):
                    output.append("a")
                    output.append(String(values.count))
                    output.append("[")
                    stack.append(.text("]"))
                    for child in values.reversed() {
                        stack.append(.value(child))
                    }
                case .object(let values):
                    let keys = values.keys.sorted()
                    output.append("o")
                    output.append(String(keys.count))
                    output.append("{")
                    stack.append(.text("}"))
                    for key in keys.reversed() {
                        guard let child = values[key] else { continue }
                        stack.append(.value(child))
                        stack.append(.text("k\(key.utf8.count):\(key);"))
                    }
                }
            }
        }

        return output
    }

}
