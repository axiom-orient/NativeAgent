import Foundation
import DocumentCore

public enum ASKHWPError: Error, Sendable, Hashable, LocalizedError {
    case emptyInput
    case unsupportedFormat(String)
    case unsupportedFeature(String)
    case malformedContainer(String)
    case malformedDocument(String)
    case resourceNotFound(String)
    case decompressionFailed(String)
    case xmlParsingFailed(String)
    case fileReadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "HWP/HWPX input is empty."
        case .unsupportedFormat(let message):
            return "Unsupported HWP/HWPX format: \(message)"
        case .unsupportedFeature(let message):
            return "Unsupported HWP/HWPX feature: \(message)"
        case .malformedContainer(let message):
            return "Malformed HWP/HWPX container: \(message)"
        case .malformedDocument(let message):
            return "Malformed HWP/HWPX document: \(message)"
        case .resourceNotFound(let path):
            return "HWP/HWPX resource not found: \(path)"
        case .decompressionFailed(let message):
            return "HWP/HWPX decompression failed: \(message)"
        case .xmlParsingFailed(let message):
            return "HWPX XML parsing failed: \(message)"
        case .fileReadFailed(let path):
            return "Failed to read HWP/HWPX file: \(path)"
        }
    }
}
