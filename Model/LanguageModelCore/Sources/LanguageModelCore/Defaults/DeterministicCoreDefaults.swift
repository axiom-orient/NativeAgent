import Foundation

public enum DeterministicCoreDefaults {
    public static let timestamp = Date(timeIntervalSince1970: 0)

    public static func identifier(prefix: String, components: [String]) -> String {
        let payload = ([prefix] + components).joined(separator: "\u{1f}")
        return "\(prefix)-\(SHA1HexDigest.hex(payload).prefix(16))"
    }

    public static func dateComponent(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1_000))
    }

    public static func metadataComponent(_ metadata: [String: JSONValue]) -> String {
        JSONValue.object(metadata).stableIdentityString()
    }

    public static func toolCallsComponent(_ toolCalls: [ToolCall]) -> String {
        let encodedCalls = toolCalls.map { call in
            JSONValue.object([
                "id": .string(call.id),
                "name": .string(call.name),
                "arguments": call.arguments,
                "metadata": .object(call.metadata)
            ])
        }
        return JSONValue.array(encodedCalls).stableIdentityString()
    }
}
