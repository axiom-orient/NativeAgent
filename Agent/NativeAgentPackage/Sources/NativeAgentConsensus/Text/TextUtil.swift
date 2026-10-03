import Foundation
import NativeAgentDomain

enum TextUtil {
    private static let dashDotCharacterSet = CharacterSet(charactersIn: "-.")

    static func normalizeText(_ parts: String?...) -> String {
        normalizeText(parts.compactMap { $0 })
    }

    static func normalizeText(_ parts: [String]) -> String {
        let scalars = parts.joined(separator: " ").lowercased().unicodeScalars
        var output = String.UnicodeScalarView()
        var previousWasSeparator = true
        let alphanumerics = CharacterSet.alphanumerics

        for scalar in scalars {
            let isWord = alphanumerics.contains(scalar) || scalar == "_"
            if isWord {
                output.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                output.append(" ")
                previousWasSeparator = true
            }
        }

        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func dedupeStable(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        output.reserveCapacity(values.count)

        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard seen.insert(value).inserted else { continue }
            output.append(value)
        }
        return output
    }

    static func dedupeStable<T: Hashable>(_ values: [T], transform: (T) -> T?) -> [T] {
        var seen = Set<T>()
        var output: [T] = []
        for value in values {
            guard let transformed = transform(value) else { continue }
            guard seen.insert(transformed).inserted else { continue }
            output.append(transformed)
        }
        return output
    }

    static func stableFacetPairs(_ facets: [String: String]) -> [String] {
        facets
            .keys
            .sorted()
            .map { key in
                "\(key.trimmingCharacters(in: .whitespacesAndNewlines))=\(facets[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines))"
            }
    }

    static func slug(_ value: String) -> String {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return "other" }

        var output = ""
        var previousWasDash = false
        let alphanumerics = CharacterSet.alphanumerics

        for scalar in lowered.unicodeScalars {
            if alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
        }

        output = output.trimmingCharacters(in: dashDotCharacterSet)
        if output.isEmpty {
            return "other"
        }
        return output
    }

    static func primaryClass(_ problem: ProblemPacket) -> String {
        let direct = problem.primaryClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !direct.isEmpty { return direct }
        let facet = problem.facets["primary_class"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !facet.isEmpty { return facet }
        return "other"
    }

    static func shortHash(_ text: String) -> String {
        let normalized = normalizeText([text])
        return SHA1HexDigest.hex(normalized).prefix(12).lowercased()
    }

    static func problemFingerprint(_ problem: ProblemPacket) -> String {
        var parts: [String] = [
            primaryClass(problem),
            problem.objective,
            problem.observedIssue,
            problem.candidate ?? ""
        ]
        parts.append(contentsOf: problem.tags.sorted())
        parts.append(contentsOf: stableFacetPairs(problem.facets))
        return shortHash(parts.joined(separator: " "))
    }

}
