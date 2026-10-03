import LanguageModelCore
import Foundation

public enum SessionMessagePersistence: Sendable, Equatable {
    case unchanged
    case append(startingAt: Int, messages: [AgentMessage])
    case replace(messages: [AgentMessage])
}

public enum SessionArtifactPersistence: Sendable, Equatable {
    case unchanged
    case append(startingAt: Int, artifacts: [ArtifactRecord])
    case replace(artifacts: [ArtifactRecord])
}

/// Incremental durable work derived by the session reducer.
///
/// `expectedRevision` is compared inside the same database transaction that
/// applies the new state. A mismatch is a stale-write conflict.
public struct SessionPersistenceDelta: Sendable, Equatable {
    public let expectedRevision: Int64
    public let messages: SessionMessagePersistence
    public let artifacts: SessionArtifactPersistence

    public init(
        expectedRevision: Int64,
        messages: SessionMessagePersistence = .unchanged,
        artifacts: SessionArtifactPersistence = .unchanged
    ) {
        self.expectedRevision = expectedRevision
        self.messages = messages
        self.artifacts = artifacts
    }
}

/// One visible durable session transition.
///
/// Every event and effect must belong to `snapshot.sessionID`. A transactional
/// store rejects cross-session payloads rather than publishing work outside the
/// transition's authoritative session boundary.
public struct SessionPersistenceTransaction: Sendable, Equatable {
    public let snapshot: SessionSnapshot
    public let delta: SessionPersistenceDelta
    public let events: [SessionEvent]
    public let effects: [EffectRecord]

    public init(
        snapshot: SessionSnapshot,
        delta: SessionPersistenceDelta,
        events: [SessionEvent] = [],
        effects: [EffectRecord] = []
    ) {
        self.snapshot = snapshot
        self.delta = delta
        self.events = events
        self.effects = effects
    }
}

/// Minimum runtime capability for all-or-nothing state, journal, and effect
/// commits. Bounded listing and paging live outside this contract.
public protocol RuntimeTransactionalSessionStore: SessionRuntimePersistence {
    func createSession(
        _ snapshot: SessionSnapshot,
        events: [SessionEvent],
        effects: [EffectRecord]
    ) async throws

    func commit(_ transaction: SessionPersistenceTransaction) async throws
}

/// One all-or-nothing fork transition: advance the source command ledger and
/// create the isolated target session in the same durable transaction.
/// `targetEvents` and `targetEffects` must belong to `target.sessionID`.
public struct SessionForkPersistenceTransaction: Sendable, Equatable {
    public let source: SessionPersistenceTransaction
    public let target: SessionSnapshot
    public let targetEvents: [SessionEvent]
    public let targetEffects: [EffectRecord]

    public init(
        source: SessionPersistenceTransaction,
        target: SessionSnapshot,
        targetEvents: [SessionEvent] = [],
        targetEffects: [EffectRecord] = []
    ) {
        self.source = source
        self.target = target
        self.targetEvents = targetEvents
        self.targetEffects = targetEffects
    }
}

/// Minimum atomic fork capability used by runtime execution.
public protocol RuntimeAtomicSessionForkStore: RuntimeTransactionalSessionStore {
    func commitFork(_ transaction: SessionForkPersistenceTransaction) async throws
}

/// Canonical durable execution port. This is the single persistence authority
/// consumed by SessionCoordinator/AgentLoop. Broad listing APIs live outside
/// this contract.
public protocol SessionRuntimeStore:
    RuntimeTransactionalSessionStore,
    EffectLedgerStore,
    SessionRuntimeAdmissionStore
{}

