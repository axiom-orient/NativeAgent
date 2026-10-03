import LanguageModelCore

public extension JSONValue {
    func stringField(_ key: String) throws -> String {
        guard let value = objectValue?[key]?.stringValue else {
            throw AgentError.invalidToolCall("Missing string field: \(key)")
        }
        return value
    }

    func optionalStringField(_ key: String) -> String? {
        objectValue?[key]?.stringValue
    }

    func intField(_ key: String) throws -> Int {
        guard let value = objectValue?[key]?.intValue else {
            throw AgentError.invalidToolCall("Missing integer field: \(key)")
        }
        return value
    }

    func optionalIntField(_ key: String) -> Int? {
        objectValue?[key]?.intValue
    }

    func boolField(_ key: String) throws -> Bool {
        guard let value = objectValue?[key]?.boolValue else {
            throw AgentError.invalidToolCall("Missing boolean field: \(key)")
        }
        return value
    }
}
