import Foundation

func collapseWhitespace(_ value: String) -> String {
    value
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizedMarkdown(_ text: String) -> String {
    let unix = text.replacingOccurrences(of: "\r\n", with: "\n")
    let collapsed = unix.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    let filtered = collapsed
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .compactMap { line -> String? in
            let trimmed = collapseWhitespace(line)
            if trimmed.isEmpty { return "" }
            switch trimmed.lowercased() {
            case "navigation menu", "skip to main content", "toggle navigation":
                return nil
            default:
                return trimmed
            }
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return filtered.isEmpty ? "" : filtered + "\n"
}
