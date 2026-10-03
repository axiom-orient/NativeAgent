import Foundation
import NativeAgentDomain

struct RuntimeSnapshotWriter: Sendable {
    let journal: SessionJournal
    let resourceValidator: RuntimeResourceValidator?
    let transactionalStore: any RuntimeTransactionalSessionStore
    let validationIndexes: RuntimeSessionValidationIndexes

    init(
        journal: SessionJournal,
        resourceValidator: RuntimeResourceValidator? = nil,
        transactionalStore: any RuntimeTransactionalSessionStore,
        validationIndexes: RuntimeSessionValidationIndexes = RuntimeSessionValidationIndexes()
    ) {
        self.journal = journal
        self.resourceValidator = resourceValidator
        self.transactionalStore = transactionalStore
        self.validationIndexes = validationIndexes
    }


    func registerLoadedSnapshotForAdvancement(
        _ snapshot: SessionSnapshot
    ) async throws {
        guard let resourceValidator else { return }
        let validationIndex = try resourceValidator.validatedIndex(snapshot: snapshot)
        await validationIndexes.seed(validationIndex)
    }

    func discardValidationIndex(sessionID: String) async {
        await validationIndexes.remove(sessionID: sessionID)
    }

    @discardableResult
    func create(
        _ snapshot: SessionSnapshot,
        journalEntries: [SessionJournal.Entry] = []
    ) async throws -> SessionSnapshot {
        let validationIndex = try await prepareValidation(
            snapshot: snapshot,
            delta: nil
        )
        let persistedJournalEntries: [SessionJournal.Entry] = [
            .sessionCreated,
        ] + journalEntries + [
            .snapshotSaved(reason: "session_created")
        ]

        let events = try journal.events(for: persistedJournalEntries, snapshot: snapshot)
        try await transactionalStore.createSession(
            snapshot,
            events: events,
            effects: []
        )
        if let validationIndex {
            await validationIndexes.commit(validationIndex, status: snapshot.status)
        }
        return snapshot
    }

    /// Atomically records the source command identity and creates its fork.
    /// A store without this explicit capability cannot execute the public fork
    /// command because a two-transaction fallback would expose partial state.
    @discardableResult
    func fork(
        source reduction: SessionReduction,
        target: SessionSnapshot,
        sourceJournalEntries: [SessionJournal.Entry] = [],
        targetJournalEntries: [SessionJournal.Entry] = []
    ) async throws -> SessionSnapshot {
        guard let mutationReason = reduction.mutationReason else {
            throw AgentError.invariantViolation(
                "A durable fork source reduction requires a mutation reason."
            )
        }
        guard let delta = reduction.persistenceDelta else {
            throw AgentError.invariantViolation(
                "A durable fork source reduction requires an incremental persistence delta."
            )
        }
        guard let forkStore = transactionalStore as? any RuntimeAtomicSessionForkStore else {
            throw AgentError.invalidConfiguration(
                "Session fork requires a RuntimeAtomicSessionForkStore."
            )
        }

        let sourceValidationIndex = try await prepareValidation(
            snapshot: reduction.snapshot,
            delta: delta
        )
        let targetValidationIndex = try await prepareValidation(
            snapshot: target,
            delta: nil
        )
        let sourceEvents = try journal.events(
            for: sourceJournalEntries + [
                .snapshotSaved(reason: mutationReason.rawValue)
            ],
            snapshot: reduction.snapshot
        )
        let targetEvents = try journal.events(
            for: [
                .sessionCreated,
            ] + targetJournalEntries + [
                .snapshotSaved(reason: "session_created")
            ],
            snapshot: target
        )

        try await forkStore.commitFork(
            SessionForkPersistenceTransaction(
                source: SessionPersistenceTransaction(
                    snapshot: reduction.snapshot,
                    delta: delta,
                    events: sourceEvents
                ),
                target: target,
                targetEvents: targetEvents
            )
        )
        if let sourceValidationIndex {
            await validationIndexes.commit(
                sourceValidationIndex,
                status: reduction.snapshot.status
            )
        }
        if let targetValidationIndex {
            await validationIndexes.commit(
                targetValidationIndex,
                status: target.status
            )
        }
        return target
    }

    @discardableResult
    func persist(
        _ reduction: SessionReduction,
        effects: [EffectRecord] = [],
        journalEntries: [SessionJournal.Entry] = []
    ) async throws -> SessionSnapshot {
        guard let mutationReason = reduction.mutationReason else {
            throw AgentError.invariantViolation(
                "A durable session reduction requires a mutation reason."
            )
        }
        return try await persist(
            reduction.snapshot,
            delta: reduction.persistenceDelta,
            mutationReason: mutationReason,
            effects: effects,
            journalEntries: journalEntries
        )
    }

    @discardableResult
    func persist(
        _ snapshot: SessionSnapshot,
        delta: SessionPersistenceDelta?,
        mutationReason: SessionMutationReason,
        effects: [EffectRecord],
        journalEntries: [SessionJournal.Entry]
    ) async throws -> SessionSnapshot {
        let validationIndex = try await prepareValidation(
            snapshot: snapshot,
            delta: delta
        )
        let persistedJournalEntries = journalEntries + [
            .snapshotSaved(reason: mutationReason.rawValue)
        ]

        guard let delta else {
            throw AgentError.invariantViolation(
                "Transactional persistence requires an incremental session delta."
            )
        }
        let events = try journal.events(
            for: persistedJournalEntries,
            snapshot: snapshot
        )
        try await transactionalStore.commit(
            SessionPersistenceTransaction(
                snapshot: snapshot,
                delta: delta,
                events: events,
                effects: effects
            )
        )
        if let validationIndex {
            await validationIndexes.commit(validationIndex, status: snapshot.status)
        }
        return snapshot
    }

    private func prepareValidation(
        snapshot: SessionSnapshot,
        delta: SessionPersistenceDelta?
    ) async throws -> RuntimeSessionValidationIndex? {
        guard let resourceValidator else { return nil }
        return try await validationIndexes.prepare(
            snapshot: snapshot,
            delta: delta,
            validator: resourceValidator
        )
    }
}

struct RuntimeToolErrorAppender: Sendable {
    let writer: RuntimeSnapshotWriter
    let transitions: AgentLoopSnapshotTransitions

    @discardableResult
    func append(
        callID: String,
        toolName: String,
        content: String,
        metadata: [String: JSONValue] = [:],
        definition: ToolDefinition? = nil,
        effects: [EffectRecord] = [],
        resumingFailedSession: Bool = false,
        to snapshot: SessionSnapshot
    ) async throws -> SessionSnapshot {
        let reduction = try transitions.appendingToolError(
            callID: callID,
            toolName: toolName,
            content: content,
            metadata: metadata,
            definition: definition,
            resumingFailedSession: resumingFailedSession,
            to: snapshot
        )
        let entries = reduction.snapshot.messages.last.map {
            [SessionJournal.Entry.toolError($0)]
        } ?? []
        return try await writer.persist(
            reduction,
            effects: effects,
            journalEntries: entries
        )
    }
}
