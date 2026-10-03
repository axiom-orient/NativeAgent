import Foundation
import Testing
@testable import NativeAgentDomain

private func makeReducerSnapshot(
    status: SessionStatus = .running,
    timestamp: Date = Date(timeIntervalSince1970: 1)
) -> SessionSnapshot {
    SessionSnapshot(
        sessionID: "session-reducer",
        status: status,
        createdAt: timestamp,
        updatedAt: timestamp,
        messages: [
            AgentMessage(
                id: "message-user",
                role: .user,
                content: "seed",
                createdAt: timestamp
            )
        ]
    )
}

@Test
func sessionReducerModelsWaitSignalAndPersistenceEffectsPurely() throws {
    let startedAt = Date(timeIntervalSince1970: 1)
    let waitedAt = Date(timeIntervalSince1970: 2)
    let signaledAt = Date(timeIntervalSince1970: 3)
    let initial = makeReducerSnapshot(timestamp: startedAt)
    let waitState = SessionWaitState.signal(
        identifier: "sync.ready",
        createdAt: waitedAt,
        details: ["source": .string("push")]
    )

    let waiting = try SessionReducer.reduce(
        .enterWait(waitState, updatedAt: waitedAt),
        state: initial
    )

    #expect(waiting.snapshot.status == .waiting)
    #expect(waiting.snapshot.waitState == waitState)
    #expect(waiting.snapshot.lastSignal == nil)
    #expect(waiting.mutationReason == .waitEntered)
    #expect(initial.status == .running)
    #expect(initial.waitState == nil)

    let signal = SessionSignal(
        identifier: "sync.ready",
        payload: .object(["revision": .integer(7)]),
        receivedAt: signaledAt
    )
    let resumed = try SessionReducer.reduce(
        .receiveSignal(signal, updatedAt: signaledAt),
        state: waiting.snapshot
    )

    #expect(resumed.snapshot.status == .running)
    #expect(resumed.snapshot.waitState == nil)
    #expect(resumed.snapshot.lastSignal == signal)
    #expect(resumed.mutationReason == .signalReceived)
    #expect(waiting.snapshot.status == .waiting)
}

@Test
func sessionReducerRejectsIllegalTerminalMutation() throws {
    let timestamp = Date(timeIntervalSince1970: 2)
    let completed = try SessionReducer.reduce(
        .complete(updatedAt: timestamp),
        state: makeReducerSnapshot()
    ).snapshot

    #expect(completed.status == .completed)
    #expect(throws: AgentError.self) {
        try SessionReducer.reduce(
            .append(
                messages: [AgentMessage(role: .assistant, content: "late")],
                artifacts: completed.artifacts,
                updatedAt: timestamp.addingTimeInterval(1),
                reason: .assistantTurnAppended
            ),
            state: completed
        )
    }

    #expect(throws: AgentError.self) {
        try SessionReducer.reduce(
            .resume(updatedAt: timestamp.addingTimeInterval(1)),
            state: completed
        )
    }

    #expect(throws: AgentError.self) {
        try SessionReducer.reduce(
            .resume(updatedAt: timestamp.addingTimeInterval(1)),
            state: makeReducerSnapshot()
        )
    }

    let waiting = try SessionReducer.reduce(
        .enterWait(
            .signal(identifier: "resume-requires-failure", createdAt: timestamp),
            updatedAt: timestamp
        ),
        state: makeReducerSnapshot()
    ).snapshot
    #expect(throws: AgentError.self) {
        try SessionReducer.reduce(
            .resume(updatedAt: timestamp.addingTimeInterval(1)),
            state: waiting
        )
    }
}

@Test
func sessionReducerRecordsCommandMetadataOnCompletedSession() throws {
    let timestamp = Date(timeIntervalSince1970: 3)
    let completed = try SessionReducer.reduce(
        .complete(updatedAt: timestamp),
        state: makeReducerSnapshot()
    ).snapshot
    let metadata: [String: JSONValue] = [
        "native-agent.command.operations": .object(["fork": .integer(completed.revision)])
    ]

    let recorded = try SessionReducer.reduce(
        .recordCommand(metadata, updatedAt: timestamp.addingTimeInterval(1)),
        state: completed
    )

    #expect(recorded.snapshot.status == .completed)
    #expect(recorded.snapshot.failure == nil)
    #expect(recorded.snapshot.metadata == metadata)
    #expect(recorded.snapshot.revision == completed.revision + 1)
    #expect(recorded.mutationReason == .commandRecorded)
    #expect(recorded.persistenceDelta == SessionPersistenceDelta(expectedRevision: completed.revision))
}

@Test
func structuredFailureIsDurableAndResumeClearsOnlyFailureState() throws {
    let timestamp = Date(timeIntervalSince1970: 5)
    let failure = SessionFailure(
        code: "provider_unavailable",
        message: "Provider is offline.",
        occurredAt: timestamp,
        details: ["retryable": .bool(true)]
    )
    let failed = try SessionReducer.reduce(
        .fail(failure, updatedAt: timestamp, reason: .sessionFailed),
        state: makeReducerSnapshot()
    )

    #expect(failed.snapshot.status == .failed)
    #expect(failed.snapshot.failure == failure)
    #expect(failed.mutationReason == .sessionFailed)

    let resumed = try SessionReducer.reduce(
        .resume(updatedAt: timestamp.addingTimeInterval(1)),
        state: failed.snapshot
    )

    #expect(resumed.snapshot.status == .running)
    #expect(resumed.snapshot.failure == nil)
    #expect(resumed.snapshot.messages == failed.snapshot.messages)
    #expect(resumed.mutationReason == .statusResumedToRunning)
}

@Test
func mismatchedSignalCannotResolvePendingWait() throws {
    let timestamp = Date(timeIntervalSince1970: 10)
    let waiting = try SessionReducer.reduce(
        .enterWait(
            .signal(identifier: "expected", createdAt: timestamp),
            updatedAt: timestamp
        ),
        state: makeReducerSnapshot()
    ).snapshot

    #expect(throws: AgentError.self) {
        try SessionReducer.reduce(
            .receiveSignal(
                SessionSignal(
                    identifier: "unexpected",
                    payload: .null,
                    receivedAt: timestamp.addingTimeInterval(1)
                ),
                updatedAt: timestamp.addingTimeInterval(1)
            ),
            state: waiting
        )
    }

    #expect(throws: AgentError.self) {
        try SessionReducer.reduce(
            .resolveWaitAndUpdateMetadata(
                signal: SessionSignal(
                    identifier: "unexpected",
                    payload: .null,
                    receivedAt: timestamp.addingTimeInterval(1)
                ),
                metadata: [:],
                updatedAt: timestamp.addingTimeInterval(1)
            ),
            state: waiting
        )
    }
}

@Test
func sessionReducerResolvesWaitAndMetadataAsOneTransition() throws {
    let timestamp = Date(timeIntervalSince1970: 11)
    let metadata: [String: JSONValue] = [
        "responseContinuationPolicy": .object([
            "mode": .string("truncatedResponseOnly"),
            "maxAdditionalTurns": .integer(1)
        ])
    ]
    let initial = makeReducerSnapshot(timestamp: timestamp)
    let waiting = try SessionReducer.reduce(
        .enterWait(
            .time(
                identifier: "timer",
                resumeAt: timestamp,
                createdAt: timestamp
            ),
            updatedAt: timestamp
        ),
        state: initial
    ).snapshot

    let cleared = try SessionReducer.reduce(
        .resolveWaitAndUpdateMetadata(
            signal: nil,
            metadata: metadata,
            updatedAt: timestamp.addingTimeInterval(1)
        ),
        state: waiting
    )

    #expect(cleared.snapshot.status == .running)
    #expect(cleared.snapshot.waitState == nil)
    #expect(cleared.snapshot.metadata == metadata)
    #expect(cleared.snapshot.revision == waiting.revision + 1)
    #expect(cleared.mutationReason == .waitCleared)
    #expect(cleared.persistenceDelta == SessionPersistenceDelta(expectedRevision: waiting.revision))

    let signalWaiting = try SessionReducer.reduce(
        .enterWait(
            .signal(identifier: "ready", createdAt: timestamp),
            updatedAt: timestamp
        ),
        state: initial
    ).snapshot
    let signal = SessionSignal(
        identifier: "ready",
        payload: .string("ok"),
        receivedAt: timestamp.addingTimeInterval(2)
    )
    let signaled = try SessionReducer.reduce(
        .resolveWaitAndUpdateMetadata(
            signal: signal,
            metadata: metadata,
            updatedAt: signal.receivedAt
        ),
        state: signalWaiting
    )

    #expect(signaled.snapshot.status == .running)
    #expect(signaled.snapshot.waitState == nil)
    #expect(signaled.snapshot.lastSignal == signal)
    #expect(signaled.snapshot.metadata == metadata)
    #expect(signaled.mutationReason == .signalReceived)
    #expect(signaled.persistenceDelta == SessionPersistenceDelta(expectedRevision: signalWaiting.revision))
}

@Test
func toolDefinitionStoresTypedEffectAndUsesMutationDefault() throws {
    let typedRead = ToolDefinition(
        name: "read.typed",
        description: "read",
        capabilityID: "test",
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic,
        effect: .readOnly,
        metadata: ["source": .string("test")]
    )
    let defaultMutation = ToolDefinition(
        name: "write.default",
        description: "read",
        capabilityID: "test",
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic
    )

    #expect(typedRead.effect == .readOnly)
    #expect(typedRead.isReadOnly)
    #expect(typedRead.metadata["source"] == .string("test"))
    #expect(defaultMutation.effect == .mutation)
    #expect(defaultMutation.isReadOnly == false)

    let roundTrip = try JSONDecoder().decode(
        ToolDefinition.self,
        from: JSONEncoder().encode(typedRead)
    )
    #expect(roundTrip.effect == .readOnly)
    #expect(roundTrip == typedRead)
}
@Test
func sessionReadLimitsAreCanonicalAcrossPagesAndQueries() throws {
    try SessionReadLimits.validatePage(
        limit: SessionReadLimits.maximumPageSize,
        offset: 0
    )
    #expect(throws: AgentError.self) {
        try SessionReadLimits.validatePage(
            limit: SessionReadLimits.maximumPageSize + 1,
            offset: 0
        )
    }

    let validated = try SessionReadLimits.validated(
        SessionListQuery(keywords: ["  alpha  ", "   "])
    )
    #expect(validated.keywords == ["alpha"])
}
