import Foundation
import NativeAgentDomain

extension SessionCoordinator {
    /// Runs one advancement under the storage-shared admission owner. The claim
    /// token stays in that owner; domain operations cannot retain or release it.
    func withSessionExecution<T: Sendable>(
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

    /// Executes a host-issued tool call without invoking the model.
    /// The call still passes through the canonical registry, validator, approval,
    /// effect ledger, artifact persistence, and durable journal path.
    @discardableResult
    public func executeToolCall(
        _ call: ToolCall,
        sessionID: String
    ) async throws -> SessionSnapshot {
        try await withSessionExecution(sessionID: sessionID) {
            let loaded = try await loadExistingSnapshotForAdvancement(sessionID: sessionID)
            let snapshot = try await prepareRunnableSnapshot(loaded)
            guard snapshot.status == .running else {
                throw AgentError.invariantViolation(
                    "Host-issued tool execution requires a running session."
                )
            }
            let context = try await makeToolExecutionContext(sessionID: sessionID)
            return try await makeAgentLoop().processHostToolCall(
                call,
                snapshot: snapshot,
                context: context
            )
        }
    }

    /// Retries a claim release that previously failed after a session operation.
    /// The claim store contract requires a failed release to leave ownership intact.
    @discardableResult
    public func retryPendingExecutionClaimRelease(sessionID: String) async throws -> Bool {
        try await executionAuthority.retryPendingRelease(
            sessionID: sessionID,
            claimStore: executionClaimStore
        )
    }

    func advanceLoadedSnapshot(
        _ loadedSnapshot: SessionSnapshot
    ) async throws -> SessionSnapshot {
        guard loadedSnapshot.status == .running else {
            throw AgentError.invariantViolation(
                "Session \(loadedSnapshot.sessionID) cannot advance from "
                    + "\(loadedSnapshot.status.rawValue); explicit continuation or retry is required."
            )
        }

        let context = try await makeToolExecutionContext(sessionID: loadedSnapshot.sessionID)
        return try await makeAgentLoop().run(
            snapshot: loadedSnapshot,
            context: context
        )
    }

    func resumeHostIssuedToolCall(
        _ call: ToolCall,
        snapshot: SessionSnapshot
    ) async throws -> SessionSnapshot {
        let context = try await makeToolExecutionContext(sessionID: snapshot.sessionID)
        return try await makeAgentLoop().processRecordedHostToolCall(
            call,
            snapshot: snapshot,
            context: context
        )
    }

    func makeAgentLoop() -> AgentLoop {
        AgentLoop(
            modelRuntime: modelRuntime,
            approvalRouter: approvalRouter,
            store: store,
            registry: registry,
            configuration: configuration,
            compactor: compactor,
            snapshotWriter: snapshotWriter,
            turnPromptAugmentor: turnPromptAugmentor,
            observer: observer,
            now: now,
            idGenerator: idGenerator
        )
    }

    func makeToolExecutionContext(sessionID: String) async throws -> ToolExecutionContext {
        ToolExecutionContext(
            sessionID: sessionID,
            sessionDirectoryURL: try await store.sessionDirectoryURL(sessionID: sessionID),
            sandboxRootURL: try await store.sandboxRootURL()
        )
    }
}
