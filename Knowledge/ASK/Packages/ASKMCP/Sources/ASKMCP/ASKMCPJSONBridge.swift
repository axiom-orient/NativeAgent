import Foundation
import MCP

/// Bridges between MCP JSON value trees and typed ASK payloads without
/// introducing a second field-naming convention: arguments serialize straight
/// into the canonical `Codable` representation of each contract type.
enum ASKMCPJSONBridge {
    static func envelopeData(_ arguments: [String: MCPJSONValue]) throws -> Data {
        try MCPJSONValue.object(arguments).encoded()
    }

    static func structuredValue(_ payload: some Encodable) throws -> MCPJSONValue {
        let parsed = try MCPJSONValue.parse(JSONEncoder().encode(payload))
        return unwrapSyntheticEnumCaseWrapper(parsed)
    }

    static func text(_ payload: some Encodable) throws -> String {
        let data = try structuredValue(payload).encoded()
        return String(decoding: data, as: UTF8.self)
    }

    /// This toolchain's synthesized enum Codable wraps even single-payload
    /// cases as `{"case": {"_0": payload}}`; expose the flat `{"case":
    /// payload}` shape to agents instead.
    private static func unwrapSyntheticEnumCaseWrapper(_ value: MCPJSONValue) -> MCPJSONValue {
        guard case .object(let root) = value, root.count == 1,
              let entry = root.first, case .object(let inner) = entry.value,
              inner.count == 1, let wrapped = inner["_0"]
        else { return value }
        return .object([entry.key: wrapped])
    }
}
