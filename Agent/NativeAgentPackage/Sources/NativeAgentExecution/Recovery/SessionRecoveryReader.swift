import Foundation
import NativeAgentDomain

/// Provider-independent durable recovery/read boundary.
///
/// This type deliberately has no `ModelRuntime`: inspection and claim-release recovery must remain
/// available when the selected provider is unavailable. It shares the same resolvers and validators
/// used by `SessionCoordinator` rather than introducing a second recovery policy.
package struct SessionRecoveryReader: Sendable {
    let store: any SessionRuntimeStore
    let registry: ToolRegistry
    let resourceValidator: RuntimeResourceValidator
    let configuration: RuntimeConfiguration
    let executionClaimStore: (any SessionExecutionClaimStore)?
    let executionAuthority: SessionExecutionAuthority
    let now: @Sendable () -> Date
    let idGenerator: @Sendable () -> String
    let snapshotWriter: RuntimeSnapshotWriter
    let toolErrorAppender: RuntimeToolErrorAppender

    package init(
        runtimeStore: any SessionRuntimeStore,
        executionClaimStore: (any SessionExecutionClaimStore)?,
        executionAuthority: SessionExecutionAuthority,
        toolPacks: [any ToolPack],
        contractOnlyDefinitions: [ToolDefinition] = [],
        configuration: RuntimeConfiguration,
        now: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) throws {
        let registry = try ToolRegistry(
            toolPacks: toolPacks,
            contractOnlyDefinitions: contractOnlyDefinitions
        )
        let resolvedClaimStore = executionClaimStore ?? (runtimeStore as? any SessionExecutionClaimStore)
        try configuration.validate(
            toolDefinitions: registry.definitions,
            executionClaimStore: resolvedClaimStore
        )
        let validator = RuntimeResourceValidator(limits: configuration.resourceLimits)
        try validator.validate(toolDefinitions: registry.definitions)
        self.store = runtimeStore
        self.registry = registry
        self.resourceValidator = validator
        self.configuration = configuration
        self.executionClaimStore = resolvedClaimStore
        self.executionAuthority = executionAuthority
        let persistedClock = PersistedTimestamp.clock(now)
        self.now = persistedClock
        self.idGenerator = idGenerator
        let journal = SessionJournal(now: persistedClock, idGenerator: idGenerator)
        let writer = RuntimeSnapshotWriter(
            journal: journal,
            resourceValidator: validator,
            transactionalStore: runtimeStore
        )
        self.snapshotWriter = writer
        self.toolErrorAppender = RuntimeToolErrorAppender(
            writer: writer,
            transitions: AgentLoopSnapshotTransitions(
                now: persistedClock,
                idGenerator: idGenerator,
                maximumFailureMessageUTF8Bytes: configuration.resourceLimits.maxFailureMessageUTF8Bytes
            )
        )
    }

    package func pendingApprovalRequest(sessionID: String) async throws -> ApprovalRequest? {
        let snapshot = try await loadExistingSnapshot(sessionID: sessionID)
        guard snapshot.status == .waiting, snapshot.waitState?.kind == .approval else { return nil }
        return try PendingApprovalResolver(registry: registry).request(from: snapshot)
    }

    package func pendingModelInvocation(sessionID: String) async throws -> PendingModelInvocation? {
        let snapshot = try await loadExistingSnapshot(sessionID: sessionID)
        guard snapshot.status == .waiting, snapshot.waitState?.kind == .modelInvocation else { return nil }
        return try await PendingModelInvocationResolver(store: store, now: now).pending(from: snapshot)
    }

    package func inspectRecovery(sessionID: String) async throws -> SessionRecoveryInspection {
        let snapshot = try await loadExistingSnapshot(sessionID: sessionID)
        return try await ToolEffectRecoveryInspector(
            store: store,
            registry: registry,
            resourceValidator: resourceValidator,
            now: now
        ).inspect(snapshot: snapshot)
    }

    package func resolveModelInvocation(
        sessionID: String,
        invocationID: String,
        resolution: ModelInvocationRecoveryResolution
    ) async throws -> ModelInvocationRecoveryReconciliation {
        try await withExecutionClaim(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshot(sessionID: sessionID)
            return try await ModelInvocationRecoveryReconciler(
                store: store,
                registry: registry,
                resourceValidator: resourceValidator,
                configuration: configuration,
                now: now,
                idGenerator: idGenerator,
                snapshotWriter: snapshotWriter
            ).reconcile(
                snapshot: snapshot,
                invocationID: invocationID,
                resolution: resolution
            )
        }
    }

    @discardableResult
    package func retryPendingExecutionClaimRelease(sessionID: String) async throws -> Bool {
        try await executionAuthority.retryPendingRelease(
            sessionID: sessionID,
            claimStore: executionClaimStore
        )
    }


    package func resolveToolEffect(
        sessionID: String,
        callID: String,
        resolution: ToolEffectRecoveryResolution
    ) async throws -> SessionSnapshot {
        try await withExecutionClaim(sessionID: sessionID) {
            let snapshot = try await loadExistingSnapshot(sessionID: sessionID)
            return try await ToolEffectRecoveryReconciler(
                store: store,
                registry: registry,
                resourceValidator: resourceValidator,
                configuration: configuration,
                now: now,
                idGenerator: idGenerator,
                snapshotWriter: snapshotWriter,
                toolErrorAppender: toolErrorAppender
            ).reconcile(
                persistedSnapshot: snapshot,
                sessionID: sessionID,
                callID: callID,
                resolution: resolution
            )
        }
    }

    private func withExecutionClaim<T: Sendable>(
        sessionID: String,
        operation: () async throws -> T
    ) async throws -> T {
        try await executionAuthority.withExecution(
            sessionID: sessionID,
            safety: configuration.safetyPolicy.sessionExecution,
            claimStore: executionClaimStore
        ) {
            do {
                return try await operation()
            } catch {
                await snapshotWriter.discardValidationIndex(sessionID: sessionID)
                throw error
            }
        }
    }

    package func loadArtifact(sessionID: String, artifactID: String) async throws -> Data {
        try await store.loadArtifact(sessionID: sessionID, artifactID: artifactID)
    }

    package func toolEffect(sessionID: String, callID: String) async throws -> EffectRecord? {
        let normalized = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw AgentError.invalidToolCall("Tool effect callID must not be empty.")
        }
        return try await store.loadEffect(sessionID: sessionID, scope: .toolCall, key: normalized)
    }

    private func loadExistingSnapshot(sessionID: String) async throws -> SessionSnapshot {
        guard let snapshot = try await store.loadSnapshot(sessionID: sessionID) else {
            throw AgentError.sessionNotFound(sessionID)
        }
        try resourceValidator.validate(snapshot: snapshot)
        return snapshot
    }
}
