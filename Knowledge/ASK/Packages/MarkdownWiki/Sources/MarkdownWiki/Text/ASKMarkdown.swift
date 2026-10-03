import Foundation

public enum ASKMarkdownSupport {
    public static func title(from markdown: String, fallback: String) -> String {
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return fallback
    }

    public static func snippet(from markdown: String, limit: Int = 160) -> String {
        let text = markdown
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: " ")
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }
}
