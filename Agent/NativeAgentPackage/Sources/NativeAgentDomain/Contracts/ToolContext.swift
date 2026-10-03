import LanguageModelCore
import Foundation

/// Immutable execution context exposed to tools.
///
/// Tools may inspect their sandbox and session directories, but durable artifact
/// persistence is owned exclusively by the runtime. A tool returns
/// `ArtifactWriteRequest` values through `ToolResult.artifacts`; it cannot write
/// artifact metadata or bypass the session transaction boundary.
public struct ToolExecutionContext: Sendable {
    public let sessionID: String
    public let sessionDirectoryURL: URL
    public let sandboxRootURL: URL

    public init(
        sessionID: String,
        sessionDirectoryURL: URL,
        sandboxRootURL: URL
    ) {
        self.sessionID = sessionID
        self.sessionDirectoryURL = sessionDirectoryURL
        self.sandboxRootURL = sandboxRootURL
    }
}
