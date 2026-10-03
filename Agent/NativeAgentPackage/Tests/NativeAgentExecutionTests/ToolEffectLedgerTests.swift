import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution

private actor InMemoryEffectLedgerStore: EffectLedgerStore {
    private var records: [String: EffectRecord] = [:]

    func loadEffect(sessionID: String, scope: EffectScope, key: String) async throws -> EffectRecord? {
        records[storageKey(sessionID: sessionID, scope: scope, key: key)]
    }

    func saveEffect(_ effect: EffectRecord) async throws {
        records[storageKey(sessionID: effect.sessionID, scope: effect.scope, key: effect.key)] = effect
    }

    private func storageKey(sessionID: String, scope: EffectScope, key: String) -> String {
        "\(sessionID)|\(scope.rawValue)|\(key)"
    }
}

private func makeMutatingToolDefinition(name: String = "files.writeText") -> ToolDefinition {
    ToolDefinition(
        name: name,
        description: "Write a text file.",
        capabilityID: .files,
        inputSchema: ToolSchema.object(
            properties: [
                "path": ToolSchema.string(description: "Path"),
                "content": ToolSchema.string(description: "Content")
            ],
            required: ["path", "content"]
        ),
        approvalPolicy: .requireApproval
    )
}

@Test
func effectRecordEventsReturnIndependentTerminalSnapshots() throws {
    let createdAt = Date(timeIntervalSince1970: 1)
    let completedAt = Date(timeIntervalSince1970: 2)
    let original = EffectRecord(
        sessionID: "session-1",
        scope: .toolCall,
        key: "call-1",
        effectType: "files.writeText",
        status: .started,
        createdAt: createdAt,
        updatedAt: createdAt,
        input: .object(["path": .string("result.txt")])
    )

    let completed = original.applying(
        .completed(
            effectType: "files.writeText",
            result: .object(["content": .string("done")]),
            metadata: ["source": .string("test")],
            updatedAt: completedAt
        )
    )

    #expect(original.status == .started)
    #expect(original.result == nil)
    #expect(original.error == nil)
    #expect(original.updatedAt == createdAt)
    #expect(completed.status == .completed)
    #expect(completed.result == .object(["content": .string("done")]))
    #expect(completed.error == nil)
    #expect(completed.updatedAt == completedAt)
    try completed.validateState()
}

@Test
func toolEffectLedgerCompletedAndFailedRecordsUseCallIDAndPreserveInput() async throws {
    let store = InMemoryEffectLedgerStore()
    let ledger = ToolEffectLedger(
        store: store,
        now: { Date(timeIntervalSince1970: 123) }
    )
    let definition = makeMutatingToolDefinition()

    let completedCall = ToolCall(
        id: "call-completed",
        name: definition.name,
        arguments: ["path": "done.txt", "content": "alpha"]
    )
    let terminalCompleted = try await ledger.completedRecord(
        call: completedCall,
        definition: definition,
        sessionID: "session-1",
        message: AgentMessage(
            role: .tool,
            content: "done",
            toolCallID: completedCall.id,
            toolName: completedCall.name
        ),
        artifacts: []
    )
    if let terminalCompleted {
        try await store.saveEffect(terminalCompleted)
    }

    let completedRecord = try #require(
        await store.loadEffect(sessionID: "session-1", scope: .toolCall, key: completedCall.id)
    )
    #expect(completedRecord.key == completedCall.id)
    #expect(completedRecord.status == .completed)
    #expect(try completedRecord.input.decode(ToolCall.self) == completedCall)

    let failedCall = ToolCall(
        id: "call-failed",
        name: definition.name,
        arguments: ["path": "failed.txt", "content": "beta"]
    )
    let terminalFailed = try await ledger.failedRecord(
        call: failedCall,
        definition: definition,
        sessionID: "session-1",
        error: "write failed"
    )
    if let terminalFailed {
        try await store.saveEffect(terminalFailed)
    }

    let failedRecord = try #require(
        await store.loadEffect(sessionID: "session-1", scope: .toolCall, key: failedCall.id)
    )
    #expect(failedRecord.key == failedCall.id)
    #expect(failedRecord.status == .failed)
    #expect(failedRecord.error == "write failed")
    #expect(try failedRecord.input.decode(ToolCall.self) == failedCall)
}

@Test
func toolEffectLedgerPolicyReducesStartedAndCompletedReceiptsWithoutStoreIO() throws {
    let definition = makeMutatingToolDefinition()
    let call = ToolCall(
        id: "call-policy",
        name: definition.name,
        arguments: ["path": "policy.txt", "content": "value"]
    )
    let started = try ToolEffectLedgerPolicy.makeStartedRecord(
        call: call,
        definition: definition,
        sessionID: "session-policy",
        timestamp: Date(timeIntervalSince1970: 10)
    )

    switch try ToolEffectLedgerPolicy.decision(
        record: started,
        call: call,
        definition: definition,
        sessionID: "session-policy"
    ) {
    case .block(let code, let reason):
        #expect(code == .unknownOutcome)
        #expect(reason.contains("already started"))
    case .execute, .replay:
        Issue.record("A started mutating effect must block automatic execution")
    }

    let message = AgentMessage(
        role: .tool,
        content: "done",
        toolCallID: call.id,
        toolName: call.name
    )
    let completed = try ToolEffectLedgerPolicy.makeTerminalRecord(
        from: started,
        call: call,
        definition: definition,
        sessionID: "session-policy",
        outcome: .completed(message: message, artifacts: []),
        timestamp: Date(timeIntervalSince1970: 11)
    )

    #expect(started.status == .started)
    #expect(completed.status == .completed)
    switch try ToolEffectLedgerPolicy.decision(
        record: completed,
        call: call,
        definition: definition,
        sessionID: "session-policy"
    ) {
    case let .replay(replayedMessage, artifacts):
        #expect(replayedMessage == message)
        #expect(artifacts.isEmpty)
    case .execute, .block:
        Issue.record("A completed effect must replay its durable payload")
    }
}

@Test
func toolEffectLedgerPolicyRejectsConflictingReceiptIdentityAndTerminalRewrite() throws {
    let definition = makeMutatingToolDefinition()
    let call = ToolCall(
        id: "call-original",
        name: definition.name,
        arguments: ["path": "a.txt", "content": "a"]
    )
    let started = try ToolEffectLedgerPolicy.makeStartedRecord(
        call: call,
        definition: definition,
        sessionID: "session-policy",
        timestamp: Date(timeIntervalSince1970: 20)
    )
    let conflictingCall = ToolCall(
        id: call.id,
        name: definition.name,
        arguments: ["path": "b.txt", "content": "b"]
    )

    #expect(throws: AgentError.self) {
        _ = try ToolEffectLedgerPolicy.decision(
            record: started,
            call: conflictingCall,
            definition: definition,
            sessionID: "session-policy"
        )
    }

    let completed = try ToolEffectLedgerPolicy.makeTerminalRecord(
        from: started,
        call: call,
        definition: definition,
        sessionID: "session-policy",
        outcome: .completed(
            message: AgentMessage(
                role: .tool,
                content: "done",
                toolCallID: call.id,
                toolName: call.name
            ),
            artifacts: []
        ),
        timestamp: Date(timeIntervalSince1970: 21)
    )

    #expect(throws: AgentError.self) {
        _ = try ToolEffectLedgerPolicy.makeTerminalRecord(
            from: completed,
            call: call,
            definition: definition,
            sessionID: "session-policy",
            outcome: .failed(error: "late failure"),
            timestamp: Date(timeIntervalSince1970: 22)
        )
    }
}
