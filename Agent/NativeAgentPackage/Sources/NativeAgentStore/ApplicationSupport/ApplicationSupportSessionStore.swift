import Foundation
import NativeAgentDomain

public struct ApplicationSupportSessionStore:
    SessionRuntimeStore,
    RuntimeAtomicSessionForkStore,
    SessionEventStore,
    EffectLedgerStore,
    SessionExecutionClaimStore,
    SessionRuntimeAdmissionStore,
    SessionSummaryStore,
    SessionSummaryLookupStore,
    SessionStateViewStore,
    SessionMessagePageStore,
    SessionQueryStore
{
    public let layout: StoreLayout
    private let durableStore: SQLiteSessionStore
    private let executionClaimStore: any SessionExecutionClaimStore

    package init(
        rootURL: URL,
        artifactIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        executionClaimStore: (any SessionExecutionClaimStore)? = nil
    ) {
        self.init(
            rootURL: rootURL,
            dataPolicy: .mobileDefault,
            artifactIDGenerator: artifactIDGenerator,
            executionClaimStore: executionClaimStore
        )
    }

    package init(
        rootURL: URL,
        dataPolicy: StoreDataPolicy,
        artifactIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        executionClaimStore: (any SessionExecutionClaimStore)? = nil
    ) {
        self.layout = StoreLayout(rootURL: rootURL)
        self.durableStore = SQLiteSessionStore(
            rootURL: rootURL,
            dataPolicy: dataPolicy,
            artifactIDGenerator: artifactIDGenerator
        )
        self.executionClaimStore = executionClaimStore
            ?? ApplicationSupportFileExecutionClaimStore(rootURL: rootURL)
    }

    /// Creates a public store with an explicit execution-claim override.
    /// Application-support composition otherwise uses kernel-backed file claims.
    public init(
        rootURL: URL,
        sharedExecutionClaimStore: any SessionExecutionClaimStore,
        dataPolicy: StoreDataPolicy = .mobileDefault,
        artifactIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.init(
            rootURL: rootURL,
            dataPolicy: dataPolicy,
            artifactIDGenerator: artifactIDGenerator,
            executionClaimStore: sharedExecutionClaimStore
        )
    }

    package static func defaultRoot(
        appName: String,
        appGroupIdentifier: String? = nil,
        appGroupContainerURL: URL? = nil,
        subdirectoryName: String = StoreLayout.defaultSubdirectoryName
    ) throws -> URL {
        try StoreLayout.defaultRootURL(
            appName: appName,
            appGroupIdentifier: appGroupIdentifier,
            appGroupContainerURL: appGroupContainerURL,
            subdirectoryName: subdirectoryName
        )
    }

    public func prepare() async throws {
        try await durableStore.prepare()
    }

    public func createSession(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) async throws {
        try await durableStore.createSession(
            snapshot,
            events: events,
            effects: effects
        )
    }

    public func commit(_ transaction: SessionPersistenceTransaction) async throws {
        try await durableStore.commit(transaction)
    }

    public func commitFork(
        _ transaction: SessionForkPersistenceTransaction
    ) async throws {
        try await durableStore.commitFork(transaction)
    }

    public func loadSnapshot(sessionID: String) async throws -> SessionSnapshot? {
        try await durableStore.loadSnapshot(sessionID: sessionID)
    }

    public func loadSessionRuntimeAdmission(
        sessionID: String
    ) async throws -> SessionRuntimeAdmission? {
        try await durableStore.loadSessionRuntimeAdmission(sessionID: sessionID)
    }

    public func listSessionSummaries(
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> [SessionSummary] {
        try await durableStore.listSessionSummaries(limit: limit, offset: offset)
    }

    public func loadSessionSummary(sessionID: String) async throws -> SessionSummary? {
        try await durableStore.loadSessionSummary(sessionID: sessionID)
    }

    public func loadSessionStateView(sessionID: String) async throws -> SessionStateView? {
        try await durableStore.loadSessionStateView(sessionID: sessionID)
    }

    public func loadSessionMessages(
        sessionID: String,
        offset: Int = 0,
        limit: Int = 100
    ) async throws -> SessionMessagePage {
        try await durableStore.loadSessionMessages(
            sessionID: sessionID,
            offset: offset,
            limit: limit
        )
    }

    public func querySessionList(
        _ query: SessionListQuery
    ) async throws -> [SessionListItem] {
        try await durableStore.querySessionList(query)
    }

    public func searchSessionMessages(
        _ query: SessionMessageSearchQuery
    ) async throws -> SessionMessageSearchPage {
        try await durableStore.searchSessionMessages(query)
    }

    public func loadEvents(sessionID: String) async throws -> [SessionEvent] {
        try await durableStore.loadEvents(sessionID: sessionID)
    }

    public func loadEffect(sessionID: String, scope: EffectScope, key: String) async throws -> EffectRecord? {
        try await durableStore.loadEffect(
            sessionID: sessionID,
            scope: scope,
            key: key
        )
    }

    public func saveEffect(_ effect: EffectRecord) async throws {
        try await durableStore.saveEffect(effect)
    }

    public func acquireExecutionClaim(sessionID: String) async throws -> SessionExecutionClaim {
        try await executionClaimStore.acquireExecutionClaim(sessionID: sessionID)
    }

    public func releaseExecutionClaim(_ claim: SessionExecutionClaim) async throws {
        try await executionClaimStore.releaseExecutionClaim(claim)
    }

    public func persistArtifact(
        sessionID: String,
        artifact: ArtifactWriteRequest,
        createdAt: Date
    ) async throws -> ArtifactRecord {
        try await durableStore.persistArtifact(
            sessionID: sessionID,
            artifact: artifact,
            createdAt: createdAt
        )
    }

    public func discardUnreferencedArtifact(_ artifact: ArtifactRecord) async throws {
        try await durableStore.discardUnreferencedArtifact(artifact)
    }

    public func loadArtifact(sessionID: String, artifactID: String) async throws -> Data {
        try await durableStore.loadArtifact(
            sessionID: sessionID,
            artifactID: artifactID
        )
    }

    public func sandboxRootURL() async throws -> URL {
        try await durableStore.sandboxRootURL()
    }

    public func sessionDirectoryURL(sessionID: String) async throws -> URL {
        try await durableStore.sessionDirectoryURL(sessionID: sessionID)
    }
}
