import Foundation
import NativeAgentDomain
import NativeAgentExecution
import NativeAgentStore

/// Storage selection without exposing coordinator wiring to applications.
public struct AgentStorage: Sendable {
    package let store: any SessionRuntimeStore
    package let executionClaimStore: (any SessionExecutionClaimStore)?
    package let executionAuthority: SessionExecutionAuthority

    /// Canonical durable runtime construction.
    public init(
        runtimePersistence: any SessionRuntimeStore,
        executionClaimStore: (any SessionExecutionClaimStore)? = nil
    ) {
        self.store = runtimePersistence
        self.executionClaimStore = executionClaimStore
            ?? (runtimePersistence as? any SessionExecutionClaimStore)
        self.executionAuthority = SessionExecutionAuthority()
    }

    /// Package-local construction for a root that has already been resolved by a
    /// higher-level data-store facade.
    package init(
        rootURL: URL,
        executionClaimStore: (any SessionExecutionClaimStore)? = nil
    ) {
        self.init(
            runtimePersistence: ApplicationSupportSessionStore(
                rootURL: rootURL,
                executionClaimStore: executionClaimStore
            )
        )
    }

    public static func applicationSupport(
        appName: String,
        appGroupIdentifier: String? = nil,
        appGroupContainerURL: URL? = nil,
        subdirectoryName: String = StoreLayout.defaultSubdirectoryName,
        executionClaimStore: (any SessionExecutionClaimStore)? = nil
    ) throws -> AgentStorage {
        let root = try applicationSupportRootURL(
            appName: appName,
            appGroupIdentifier: appGroupIdentifier,
            appGroupContainerURL: appGroupContainerURL,
            subdirectoryName: subdirectoryName
        )
        return AgentStorage(rootURL: root, executionClaimStore: executionClaimStore)
    }

    /// Resolves and validates the shared application-support root exactly once.
    package static func applicationSupportRootURL(
        appName: String,
        appGroupIdentifier: String? = nil,
        appGroupContainerURL: URL? = nil,
        subdirectoryName: String = StoreLayout.defaultSubdirectoryName
    ) throws -> URL {
        guard appGroupContainerURL == nil || appGroupIdentifier != nil else {
            throw AgentError.invalidConfiguration(
                "An App Group container URL requires an App Group identifier."
            )
        }
        return try ApplicationSupportSessionStore.defaultRoot(
            appName: appName,
            appGroupIdentifier: appGroupIdentifier,
            appGroupContainerURL: appGroupContainerURL,
            subdirectoryName: subdirectoryName
        )
    }

    /// Deterministic host-owned location with explicit execution ownership.
    public static func directory(
        _ rootURL: URL,
        executionClaimStore: any SessionExecutionClaimStore
    ) -> AgentStorage {
        AgentStorage(rootURL: rootURL, executionClaimStore: executionClaimStore)
    }

    /// Package-local deterministic directory using the same kernel-backed claim authority.
    package static func directory(_ rootURL: URL) -> AgentStorage {
        AgentStorage(rootURL: rootURL)
    }

    public func sessions(limit: Int = 100, offset: Int = 0) async throws -> [SessionSummary] {
        try SessionReadLimits.validatePage(limit: limit, offset: offset)
        try await store.prepare()
        guard let summaryStore = store as? any SessionSummaryStore else {
            throw AgentError.unsupportedSurface(
                "Session listing requires a SessionSummaryStore."
            )
        }
        return try await summaryStore.listSessionSummaries(limit: limit, offset: offset)
    }

    public func session(id sessionID: String) async throws -> SessionSnapshot {
        try await store.prepare()
        guard let snapshot = try await store.loadSnapshot(sessionID: sessionID) else {
            throw AgentError.sessionNotFound(sessionID)
        }
        return snapshot
    }

    public func sessionSummary(id sessionID: String) async throws -> SessionSummary {
        try await store.prepare()
        if let summaryStore = store as? any SessionSummaryLookupStore {
            guard let summary = try await summaryStore.loadSessionSummary(sessionID: sessionID) else {
                throw AgentError.sessionNotFound(sessionID)
            }
            return summary
        }
        guard let snapshot = try await store.loadSnapshot(sessionID: sessionID) else {
            throw AgentError.sessionNotFound(sessionID)
        }
        return SessionSummary(snapshot: snapshot)
    }

    public func sessionState(id sessionID: String) async throws -> SessionStateView {
        try await store.prepare()
        if let stateStore = store as? any SessionStateViewStore {
            guard let state = try await stateStore.loadSessionStateView(sessionID: sessionID) else {
                throw AgentError.sessionNotFound(sessionID)
            }
            return state
        }
        guard let snapshot = try await store.loadSnapshot(sessionID: sessionID) else {
            throw AgentError.sessionNotFound(sessionID)
        }
        return SessionStateView(
            summary: SessionSummary(snapshot: snapshot),
            metadata: snapshot.metadata,
            contextCheckpoint: snapshot.contextCheckpoint,
            waitState: snapshot.waitState,
            failure: snapshot.failure,
            lastSignal: snapshot.lastSignal
        )
    }

    public func journalRecord(sessionID: String) async throws -> AgentJournalRecord {
        let summary = try await sessionSummary(id: sessionID)
        return try AgentJournalRecord(
            sessionID: summary.sessionID,
            revision: summary.revision,
            status: summary.status,
            updatedAt: summary.updatedAt,
            messageCount: summary.messageCount,
            artifactCount: summary.artifactCount
        )
    }

    public func cloudProjection(sessionID: String) async throws -> AgentCloudProjection {
        let summary = try await sessionSummary(id: sessionID)
        let limit = min(AgentCloudProjection.maximumMessages, max(1, summary.messageCount))
        let offset = max(0, summary.messageCount - limit)
        let page = try await messages(sessionID: sessionID, offset: offset, limit: limit)
        let projectedMessages = try page.messages.map { message in
            try AgentCloudProjection.Message(
                id: message.id,
                role: message.role.rawValue,
                text: "[Content omitted from cloud projection]",
                createdAt: message.createdAt
            )
        }
        return try AgentCloudProjection(
            sessionID: summary.sessionID,
            revision: summary.revision,
            title: nil,
            status: summary.status,
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            providerID: nil,
            modelID: nil,
            messageCount: summary.messageCount,
            artifactCount: summary.artifactCount,
            messages: projectedMessages
        )
    }

    public func messages(
        sessionID: String,
        offset: Int = 0,
        limit: Int = 100
    ) async throws -> SessionMessagePage {
        try SessionReadLimits.validatePage(limit: limit, offset: offset)
        try await store.prepare()
        guard let messageStore = store as? any SessionMessagePageStore else {
            throw AgentError.unsupportedSurface(
                "Bounded session messages require a SessionMessagePageStore."
            )
        }
        return try await messageStore.loadSessionMessages(
            sessionID: sessionID,
            offset: offset,
            limit: limit
        )
    }

    public func querySessionList(
        _ query: SessionListQuery
    ) async throws -> [SessionListItem] {
        let query = try SessionReadLimits.validated(query)
        try await store.prepare()
        guard let queryStore = store as? any SessionQueryStore else {
            throw AgentError.unsupportedSurface(
                "Session queries require a SessionQueryStore."
            )
        }
        return try await queryStore.querySessionList(query)
    }

    public func searchSessionMessages(
        _ query: SessionMessageSearchQuery
    ) async throws -> SessionMessageSearchPage {
        let query = try SessionReadLimits.validated(query)
        try await store.prepare()
        guard let queryStore = store as? any SessionQueryStore else {
            throw AgentError.unsupportedSurface(
                "Session message search requires a SessionQueryStore."
            )
        }
        return try await queryStore.searchSessionMessages(query)
    }

}
