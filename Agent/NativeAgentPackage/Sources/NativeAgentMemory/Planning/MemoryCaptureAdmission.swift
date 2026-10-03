import NativeAgentDomain
import Foundation

/// Single authority for deciding whether transcript content is eligible for
/// durable memory projection. Upstream producers may mark sensitivity; only
/// this package interprets those marks as a capture decision.
enum MemoryCaptureAdmission {
    struct Flags: Sendable, Equatable {
        let isHidden: Bool
        let isSensitive: Bool
    }

    private static let hiddenKeys: Set<String> = [
        "hidden", "is_hidden", "native-agent.hidden", "native-agent.memory.hidden",
    ]

    private static let sensitiveKeys: Set<String> = [
        "credential", "credentials", "secret", "sensitive", "sensitivedata",
        "native-agent.credential", "native-agent.memory.credentials",
    ]

    static func flags(for metadata: [String: JSONValue]) -> Flags {
        Flags(
            isHidden: containsTrueFlag(metadata, keys: hiddenKeys),
            isSensitive: containsTrueFlag(metadata, keys: sensitiveKeys)
        )
    }

    static func flags(for metadata: [String: String]) -> Flags {
        Flags(
            isHidden: containsTrueFlag(metadata, keys: hiddenKeys),
            isSensitive: containsTrueFlag(metadata, keys: sensitiveKeys)
        )
    }

    private static func containsTrueFlag(
        _ metadata: [String: JSONValue],
        keys: Set<String>
    ) -> Bool {
        metadata.contains { key, value in
            guard keys.contains(key.lowercased()) else { return false }
            if value.boolValue == true { return true }
            if case .string(let text) = value {
                return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            }
            return false
        }
    }

    private static func containsTrueFlag(
        _ metadata: [String: String],
        keys: Set<String>
    ) -> Bool {
        metadata.contains { key, value in
            keys.contains(key.lowercased())
                && ["true", "1", "yes"].contains(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
        }
    }
}
