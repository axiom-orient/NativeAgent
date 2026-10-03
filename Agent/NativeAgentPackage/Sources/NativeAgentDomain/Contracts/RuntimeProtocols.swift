import Foundation
import LanguageModelCore

public protocol ToolExecutor: Sendable {
    var definition: ToolDefinition { get }
    func execute(
        call: ToolCall,
        context: ToolExecutionContext
    ) async throws -> ToolResult
}

public protocol ToolPack: Sendable {
    var packID: String { get }
    func executors() -> [any ToolExecutor]
}

public protocol ApprovalRouter: Sendable {
    func resolve(request: ApprovalRequest) async -> ApprovalDecision
}

/// Minimum non-transactional persistence surface used by the execution kernel.
/// It intentionally excludes broad browsing and non-atomic session creation.
public protocol SessionRuntimePersistence: Sendable {
    func prepare() async throws
    func loadSnapshot(sessionID: String) async throws -> SessionSnapshot?
    func persistArtifact(
        sessionID: String,
        artifact: ArtifactWriteRequest,
        createdAt: Date
    ) async throws -> ArtifactRecord
    /// Removes a staged artifact only when durable session metadata does not
    /// reference it. The operation must be idempotent.
    func discardUnreferencedArtifact(_ artifact: ArtifactRecord) async throws
    func loadArtifact(sessionID: String, artifactID: String) async throws -> Data
    func sandboxRootURL() async throws -> URL
    func sessionDirectoryURL(sessionID: String) async throws -> URL
}

/// Cheap durable header used to reject oversized or unsupported sessions
/// before decoding their complete transcript/artifact payloads.
public struct SessionRuntimeAdmission: Sendable, Equatable {
    public let schemaVersion: String
    public let revision: Int64
    public let messageCount: Int
    public let hydrationPayloadBytes: Int
    public let artifactCount: Int

    public init(
        schemaVersion: String,
        revision: Int64,
        messageCount: Int,
        hydrationPayloadBytes: Int,
        artifactCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.messageCount = messageCount
        self.hydrationPayloadBytes = hydrationPayloadBytes
        self.artifactCount = artifactCount
    }

    /// `hydrationPayloadBytes` is the sum of the encoded metadata, context
    /// checkpoint, wait, failure and signal records plus each encoded message
    /// and artifact record, matching the built-in durable store rows.
}

public protocol SessionRuntimeAdmissionStore: Sendable {
    func loadSessionRuntimeAdmission(
        sessionID: String
    ) async throws -> SessionRuntimeAdmission?
}

/// Optional read-optimized boundary for session list screens.
public protocol SessionSummaryStore: Sendable {
    func listSessionSummaries(limit: Int, offset: Int) async throws -> [SessionSummary]
}

/// Optional read-optimized boundary for one session header without loading its transcript.
public protocol SessionSummaryLookupStore: Sendable {
    func loadSessionSummary(sessionID: String) async throws -> SessionSummary?
}

public protocol SessionStateViewStore: Sendable {
    func loadSessionStateView(sessionID: String) async throws -> SessionStateView?
}

/// Optional read-optimized boundary for bounded transcript presentation.
public protocol SessionMessagePageStore: Sendable {
    func loadSessionMessages(
        sessionID: String,
        offset: Int,
        limit: Int
    ) async throws -> SessionMessagePage
}

/// One-query, bounded reads for session lists and cross-session message search.
public protocol SessionQueryStore: Sendable {
    func querySessionList(_ query: SessionListQuery) async throws -> [SessionListItem]
    func searchSessionMessages(
        _ query: SessionMessageSearchQuery
    ) async throws -> SessionMessageSearchPage
}
