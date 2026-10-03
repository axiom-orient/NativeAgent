import Foundation

public enum ASKMarkdownPathPolicy {
    public static func normalize(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw ASKMarkdownPathError.invalidPath(path)
        }
        let components = trimmed.split(separator: "/").map(String.init)
        guard !components.contains("..") else {
            throw ASKMarkdownPathError.invalidPath(path)
        }
        return components.joined(separator: "/")
    }
}

public enum ASKMarkdownPathError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPath(String)

    public var description: String {
        switch self {
        case .invalidPath(let path): "invalid Markdown path: \(path)"
        }
    }
}
