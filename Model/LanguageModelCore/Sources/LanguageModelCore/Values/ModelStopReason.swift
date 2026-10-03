import Foundation

public enum ModelStopReason: String, Codable, Sendable, Equatable, Hashable {
    case stop
    case maxTokens
    case toolUse
    case refusal
    case safety
    case contentFilter
    case recitation
    case malformedToolCall
    case unexpectedToolCall
    case tooManyToolCalls
    case other
}

public enum ModelStopReasonMetadata {
    public static let key = "native-agent.model.normalized-stop-reason"

    public static func applying(
        _ stopReason: ModelStopReason?,
        to metadata: [String: JSONValue]
    ) -> [String: JSONValue] {
        guard let stopReason else {
            return metadata
        }

        var next = metadata
        next[key] = .string(stopReason.rawValue)
        return next
    }

    public static func stopReason(from metadata: [String: JSONValue]) -> ModelStopReason? {
        guard let raw = metadata[key]?.stringValue else {
            return nil
        }
        return ModelStopReason(rawValue: raw)
    }
}
