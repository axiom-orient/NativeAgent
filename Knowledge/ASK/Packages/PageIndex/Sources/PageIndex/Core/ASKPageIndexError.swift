import Foundation

public enum ASKPageIndexError: Error, Equatable, LocalizedError, Sendable {
    case unknownConfigKeys(Set<String>)
    case invalidArguments(String)
    case fileNotFound(String)
    case unsupportedFileFormat(String)
    case invalidPagesFormat(String)
    case invalidSourceRange(start: Int, end: Int)
    case processFailure(command: String, exitCode: Int32, stderr: String)
    case decodeFailure(String)
    case dependencyUnavailable(String)
    case unsupportedOperation(String)
    case ocrRequired(String)
    case unresolvedSourceAnchor(sourceID: String, nodeID: String)

    public var errorDescription: String? {
        switch self {
        case .unknownConfigKeys(let keys):
            return "Unknown config keys: \(keys.sorted())"
        case .invalidArguments(let message):
            return message
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .unsupportedFileFormat(let path):
            return "Unsupported file format for: \(path)"
        case .invalidPagesFormat(let pages):
            return "Invalid pages format: \(pages)"
        case .invalidSourceRange(let start, let end):
            return "Invalid source range: start=\(start), end=\(end)"
        case .processFailure(let command, let exitCode, let stderr):
            return "Process failed (\(command), exit \(exitCode)): \(stderr)"
        case .decodeFailure(let description):
            return description
        case .dependencyUnavailable(let dependency):
            return "Required dependency unavailable: \(dependency)"
        case .unsupportedOperation(let message):
            return message
        case .ocrRequired(let path):
            return "OCR is required before this PDF can be indexed: \(path)"
        case .unresolvedSourceAnchor(let sourceID, let nodeID):
            return "Unresolved source anchor: sourceID=\(sourceID), nodeID=\(nodeID)"
        }
    }
}
