import Foundation
import KnowledgeCore

func decodeBridgeArgs<T: Decodable>(
    _ type: T.Type,
    tool: String,
    descriptor: ASKJSONToolDescriptor,
    from data: Data
) throws -> T {
    let payload = data.isEmpty ? Data("{}".utf8) : data
    do {
        let raw = try JSONSerialization.jsonObject(with: payload)
        guard let object = raw as? [String: Any] else {
            throw ASKJSONBridgeError.invalidArguments(
                tool: tool,
                reason: "arguments must be a JSON object"
            )
        }

        let supplied = Set(object.keys)
        let allowed = Set(descriptor.requestFields.map(\.name))
        let unknown = supplied.subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw ASKJSONBridgeError.invalidArguments(
                tool: tool,
                reason: "unknown fields: \(unknown.joined(separator: ", "))"
            )
        }

        let missing = descriptor.requestFields
            .filter(\.required)
            .map(\.name)
            .filter { !supplied.contains($0) }
            .sorted()
        guard missing.isEmpty else {
            throw ASKJSONBridgeError.invalidArguments(
                tool: tool,
                reason: "missing required fields: \(missing.joined(separator: ", "))"
            )
        }

        return try CanonicalJSON.decoder().decode(T.self, from: payload)
    } catch let error as ASKJSONBridgeError {
        throw error
    } catch {
        throw ASKJSONBridgeError.invalidArguments(
            tool: tool,
            reason: "arguments do not match the contract"
        )
    }
}

func encodeBridgeValue<T: Encodable>(_ value: T) throws -> Data {
    try CanonicalJSON.data(for: value)
}
