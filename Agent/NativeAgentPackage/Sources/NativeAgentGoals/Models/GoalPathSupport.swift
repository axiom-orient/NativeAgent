import Foundation

public enum GoalPath: Sendable {
    public static func sanitized(_ raw: String) -> String {
        let trimmed = raw.trimmedForNativeAgentGoal
        guard !trimmed.isEmpty else { return "default" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        let mapped = trimmed.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let output = String(mapped)
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return output.isEmpty ? "default" : output
    }
}

public extension String {
    var trimmedForNativeAgentGoal: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var nonEmptyForNativeAgentGoal: String? {
        let trimmed = trimmedForNativeAgentGoal
        return trimmed.isEmpty ? nil : trimmed
    }
}
