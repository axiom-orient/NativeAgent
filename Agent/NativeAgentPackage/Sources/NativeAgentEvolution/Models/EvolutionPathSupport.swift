import Foundation

public enum EvolutionPath: Sendable {
    public static func sanitized(_ raw: String) -> String {
        let trimmed = raw.trimmedForNativeAgentEvolution
        guard !trimmed.isEmpty else { return "default" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = trimmed.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let output = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return output.isEmpty ? "default" : output
    }
}

public extension String {
    var trimmedForNativeAgentEvolution: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var nonEmptyForNativeAgentEvolution: String? {
        let trimmed = trimmedForNativeAgentEvolution
        return trimmed.isEmpty ? nil : trimmed
    }
}
