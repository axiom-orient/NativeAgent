import NativeAgentDomain
import Foundation

enum BrowserTiming {
    static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }
}

public enum BrowserError: Error, Sendable, Equatable, LocalizedError {
    case invalidPolicy(String)
    case navigationBlocked(String)
    case navigationFailed(String)
    case operationInProgress
    case operationTimedOut
    case sessionClosed
    case sessionRequiresReplacement
    case invalidJavaScriptResult
    case javaScriptSourceTooLarge
    case javaScriptArgumentsTooLarge
    case javaScriptArgumentsMustBeObject
    case javaScriptResultTooLarge
    case htmlTooLarge
    case htmlExportUnavailable
    case actionTextTooLarge
    case stalePage(expected: String, actual: String)
    case elementNotFound(String)
    case unsupportedElement(String)
    case sensitiveInputDenied
    case snapshotEncodingFailed
    case snapshotTooLarge
    case contentPolicyCompilationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPolicy(message): message
        case let .navigationBlocked(destination): "Browser navigation was blocked: \(destination)."
        case let .navigationFailed(message): "Browser navigation failed: \(message)"
        case .operationInProgress: "Another browser operation is already in progress."
        case .operationTimedOut: "The browser operation timed out."
        case .sessionClosed: "This browser session is closed."
        case .sessionRequiresReplacement:
            "This browser session was interrupted during JavaScript execution and must be replaced before reuse."
        case .invalidJavaScriptResult: "Browser JavaScript returned a value outside the JSON contract."
        case .javaScriptSourceTooLarge: "Browser JavaScript source exceeds the configured byte limit."
        case .javaScriptArgumentsTooLarge: "Browser JavaScript arguments exceed the configured byte limit."
        case .javaScriptArgumentsMustBeObject: "Browser JavaScript arguments must be a JSON object."
        case .javaScriptResultTooLarge: "Browser JavaScript result exceeds the configured byte limit."
        case .htmlTooLarge: "Browser HTML input exceeds the configured byte limit."
        case .htmlExportUnavailable: "The current page has no serializable document element."
        case .actionTextTooLarge: "Browser action text exceeds the configured byte limit."
        case let .stalePage(expected, actual):
            "Browser page changed before the action (expected \(expected), actual \(actual))."
        case let .elementNotFound(identifier): "Browser element \(identifier) is no longer available."
        case let .unsupportedElement(message): message
        case .sensitiveInputDenied: "Browser automation cannot type into sensitive or file inputs."
        case .snapshotEncodingFailed: "Browser snapshot could not be encoded as PNG."
        case .snapshotTooLarge: "Browser snapshot exceeds the configured byte limit."
        case let .contentPolicyCompilationFailed(message):
            "Browser content policy could not be compiled: \(message)"
        }
    }
}

public struct BrowserPage: Sendable, Equatable, Codable {
    public let displayURL: String?
    public let title: String?
    public let isLoading: Bool

    public init(displayURL: String?, title: String?, isLoading: Bool) {
        self.displayURL = displayURL
        self.title = title
        self.isLoading = isLoading
    }
}

public struct BrowserElement: Sendable, Equatable, Codable {
    public let id: String
    public let role: String
    public let label: String
    public let isEnabled: Bool
    public let isEditable: Bool
    public let isSensitive: Bool
    public let isSelected: Bool?

    public init(
        id: String,
        role: String,
        label: String,
        isEnabled: Bool,
        isEditable: Bool,
        isSensitive: Bool,
        isSelected: Bool?
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.isEnabled = isEnabled
        self.isEditable = isEditable
        self.isSensitive = isSensitive
        self.isSelected = isSelected
    }
}

public struct BrowserObservation: Sendable, Equatable, Codable {
    public let sessionID: String
    public let pageRevision: String
    public let page: BrowserPage
    public let visibleText: String
    public let elements: [BrowserElement]
    public let visibleTextWasTruncated: Bool
    public let omittedElementCount: Int

    public init(
        sessionID: String,
        pageRevision: String,
        page: BrowserPage,
        visibleText: String,
        elements: [BrowserElement],
        visibleTextWasTruncated: Bool,
        omittedElementCount: Int
    ) {
        self.sessionID = sessionID
        self.pageRevision = pageRevision
        self.page = page
        self.visibleText = visibleText
        self.elements = elements
        self.visibleTextWasTruncated = visibleTextWasTruncated
        self.omittedElementCount = omittedElementCount
    }
}

/// A bounded serialization of the current rendered DOM. This is not the raw
/// network response and does not contain pixels drawn only into canvas/WebGL.
public struct BrowserHTMLExport: Sendable, Equatable {
    public let sessionID: String
    public let html: String
    public let pageRevision: String
    public let page: BrowserPage
    public let contentSHA256: String

    public init(
        sessionID: String,
        html: String,
        pageRevision: String,
        page: BrowserPage,
        contentSHA256: String
    ) {
        self.sessionID = sessionID
        self.html = html
        self.pageRevision = pageRevision
        self.page = page
        self.contentSHA256 = contentSHA256
    }
}

/// Result of page-world JavaScript paired with a fresh semantic observation.
/// The observation is taken after the script completes so callers can use its
/// revision for the next browser action.
public struct BrowserJavaScriptEvaluation: Sendable, Equatable {
    public let result: JSONValue
    public let observation: BrowserObservation

    public init(result: JSONValue, observation: BrowserObservation) {
        self.result = result
        self.observation = observation
    }
}
