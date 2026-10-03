import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution

private func makeArtifactRecord(id: String, filename: String) -> ArtifactRecord {
    ArtifactRecord(
        id: id,
        sessionID: "session-1",
        filename: filename,
        relativePath: "sessions/session-1/artifacts/\(filename)",
        mimeType: "text/plain",
        byteCount: 4,
        contentSHA256: String(repeating: "0", count: 64),
        createdAt: Date(timeIntervalSince1970: 1)
    )
}

@Test
func sessionSnapshotEventsReturnIndependentStateAndPreserveInvariants() {
    let createdAt = Date(timeIntervalSince1970: 1)
    let appendedAt = Date(timeIntervalSince1970: 2)
    let waitingAt = Date(timeIntervalSince1970: 3)
    let original = SessionSnapshot(
        sessionID: "session-1",
        createdAt: createdAt,
        updatedAt: createdAt,
        metadata: ["origin": .string("test")]
    )
    let message = AgentMessage(
        id: "message-1",
        role: .user,
        content: "Continue",
        createdAt: appendedAt
    )
    let artifact = makeArtifactRecord(id: "artifact-1", filename: "result.txt")

    let appended = original.applying(
        .appended(
            messages: [message],
            artifacts: [artifact],
            updatedAt: appendedAt
        )
    )
    let expectedWait = SessionWaitState.signal(
        identifier: "user-input",
        createdAt: waitingAt
    )
    let waiting = appended.applying(
        .enteredWait(
            expectedWait,
            updatedAt: waitingAt
        )
    )

    #expect(original.messages.isEmpty)
    #expect(original.artifacts.isEmpty)
    #expect(original.status == .running)
    #expect(original.waitState == nil)
    #expect(appended.messages == [message])
    #expect(appended.artifacts == [artifact])
    #expect(appended.updatedAt == appendedAt)
    #expect(waiting.status == .waiting)
    #expect(waiting.waitState == expectedWait)
    #expect(waiting.updatedAt == waitingAt)
    #expect(waiting.metadata["origin"] == .string("test"))
}

@Test
func assistantTurnPreservesStructuredContentAndTerminalFacts() throws {
    let transitions = AgentLoopSnapshotTransitions(
        now: { Date(timeIntervalSince1970: 10) },
        idGenerator: { "assistant-message-1" }
    )
    let image = ModelBinaryContent(
        mimeType: "image/png",
        data: Data([1, 2, 3]),
        filename: "result.png"
    )
    let usage = ModelUsage(inputTokens: 11, outputTokens: 7, totalTokens: 18)
    let toolCall = ToolCall(
        name: "lookup",
        arguments: .object(["query": .string("value")])
    )
    let turn = ModelTurn(
        contentParts: [.text("answer"), .image(image)],
        toolCalls: [toolCall],
        metadata: ["source": .string("provider")],
        usage: usage,
        responseID: "response-1",
        reasoningSummary: "A concise answer was produced.",
        stopReason: .maxTokens
    )
    let snapshot = SessionSnapshot(sessionID: "session-1")

    let updated = try transitions.appendingAssistantTurn(turn, to: snapshot).snapshot
    let assistant = try #require(updated.messages.last)

    #expect(assistant.id == "assistant-message-1")
    #expect(assistant.role == .assistant)
    #expect(assistant.content == turn.content)
    #expect(assistant.contentParts == turn.contentParts)
    #expect(assistant.toolCalls == turn.toolCalls)
    #expect(assistant.metadata == turn.metadata)
    #expect(assistant.usage == usage)
    #expect(assistant.responseID == "response-1")
    #expect(assistant.reasoningSummary == "A concise answer was produced.")
    #expect(assistant.stopReason == .maxTokens)
}

@Test
func toolResultEventsReturnIndependentValues() {
    let original = ToolResult.text(
        callID: "adapter-call",
        toolName: "adapter.tool",
        content: "done",
        metadata: ["source": .string("adapter")]
    )

    let normalized = original
        .applying(.identityChanged(callID: "runtime-call", toolName: "runtime.tool"))
        .applying(.metadataChanged(["source": .string("runtime")]))

    #expect(original.callID == "adapter-call")
    #expect(original.toolName == "adapter.tool")
    #expect(original.metadata["source"] == .string("adapter"))
    #expect(normalized.callID == "runtime-call")
    #expect(normalized.toolName == "runtime.tool")
    #expect(normalized.output == original.output)
    #expect(normalized.metadata["source"] == .string("runtime"))
}


@Test
func structuredToolObservationPreservesMachineEvidenceWithoutChangingHumanContent() throws {
    let transitions = AgentLoopSnapshotTransitions(
        now: { Date(timeIntervalSince1970: 10) },
        idGenerator: { "tool-message-structured" }
    )
    let artifact = makeArtifactRecord(id: "artifact-structured", filename: "evidence.txt")
    let result = ToolResult(
        callID: "call-structured",
        toolName: "files.readText",
        output: .object([
            "content": .string("hello"),
            "sha256": .string("abc123"),
            "instructionDocuments": .array([.object(["path": .string("AGENTS.md")])])
        ]),
        metadata: ["byteCount": .integer(5), "source": .string("filesystem")]
    )
    let snapshot = SessionSnapshot(sessionID: "session-1")
    let definition = ToolDefinition(
        name: "files.readText",
        description: "read",
        capabilityID: .files,
        inputSchema: ToolSchema.object(properties: [:]),
        approvalPolicy: .automatic,
        effect: .readOnly
    )

    let updated = try transitions.appendingToolResult(
        result,
        definition: definition,
        persistedArtifacts: [artifact],
        to: snapshot
    ).snapshot
    let message = try #require(updated.messages.last)

    #expect(message.content == "hello")
    #expect(message.metadata["output"]?.objectValue?["sha256"]?.stringValue == "abc123")
    #expect(message.metadata["isError"]?.boolValue == false)

    let visible = try message.modelVisibleContent()
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(visible.utf8)) as? [String: Any]
    )
    let output = try #require(object["output"] as? [String: Any])
    let metadata = try #require(object["metadata"] as? [String: Any])
    let artifacts = try #require(object["artifacts"] as? [[String: Any]])
    #expect(output["sha256"] as? String == "abc123")
    #expect(metadata["source"] as? String == "filesystem")
    #expect(metadata["byteCount"] as? Int == 5)
    #expect(artifacts.first?["id"] as? String == artifact.id)
}

@Test
func modelRequestEventsReturnIndependentValues() {
    let original = ModelRequest(
        sessionID: "session-1",
        messages: [AgentMessage(id: "user-1", role: .user, content: "Hello")],
        tools: [],
        metadata: ["source": .string("original")]
    )
    let context = AgentMessage(id: "memory-1", role: .system, content: "Remember this.")
    let augmented = original.applying(
        .contentsChanged(
            messages: [context] + original.messages,
            metadata: ["source": .string("memory"), "attached": .bool(true)]
        )
    )

    #expect(original.messages.map(\.id) == ["user-1"])
    #expect(original.metadata["source"] == .string("original"))
    #expect(augmented.messages.map(\.id) == ["memory-1", "user-1"])
    #expect(augmented.metadata["source"] == .string("memory"))
    #expect(augmented.metadata["attached"] == .bool(true))
}

@Test
func appendingToolResultDedupesArtifactsByIdentifier() throws {
    let transitions = AgentLoopSnapshotTransitions(
        now: { Date(timeIntervalSince1970: 10) },
        idGenerator: { "tool-message-1" }
    )
    let existing = makeArtifactRecord(id: "artifact-1", filename: "existing.txt")
    let inserted = makeArtifactRecord(id: "artifact-2", filename: "inserted.txt")
    let duplicate = makeArtifactRecord(id: "artifact-1", filename: "duplicate.txt")
    let snapshot = SessionSnapshot(
        sessionID: "session-1",
        artifacts: [existing]
    )

    let updated = try transitions.appendingToolResult(
        .text(
            callID: "call-1",
            toolName: "files.writeText",
            content: "done"
        ),
        definition: ToolDefinition(
            name: "files.writeText",
            description: "write",
            capabilityID: .files,
            inputSchema: ToolSchema.object(properties: [:]),
            approvalPolicy: .requireApproval
        ),
        persistedArtifacts: [duplicate, inserted, inserted],
        to: snapshot
    ).snapshot

    #expect(updated.artifacts.map(\.id) == ["artifact-1", "artifact-2"])
    #expect(updated.artifacts.map(\.filename) == ["existing.txt", "inserted.txt"])
}

@Test
func appendingReplayedToolResultDedupesArtifactsByIdentifier() throws {
    let transitions = AgentLoopSnapshotTransitions(
        now: { Date(timeIntervalSince1970: 10) },
        idGenerator: { "tool-message-1" }
    )
    let existing = makeArtifactRecord(id: "artifact-1", filename: "existing.txt")
    let inserted = makeArtifactRecord(id: "artifact-2", filename: "inserted.txt")
    let snapshot = SessionSnapshot(
        sessionID: "session-1",
        artifacts: [existing]
    )

    let updated = try transitions.appendingReplayedToolResult(
        message: AgentMessage(
            id: "message-1",
            role: .tool,
            content: "done",
            createdAt: Date(timeIntervalSince1970: 1),
            toolCallID: "call-1",
            toolName: "files.writeText"
        ),
        definition: ToolDefinition(
            name: "files.writeText",
            description: "write",
            capabilityID: .files,
            inputSchema: ToolSchema.object(properties: [:]),
            approvalPolicy: .requireApproval
        ),
        artifacts: [existing, inserted, inserted],
        to: snapshot
    ).snapshot

    #expect(updated.artifacts.map(\.id) == ["artifact-1", "artifact-2"])
    #expect(updated.artifacts.map(\.filename) == ["existing.txt", "inserted.txt"])
    #expect(updated.messages.last?.metadata["effectReplayed"]?.boolValue == true)
}

@Test
func runtimeFailureMessageIsBoundedWithExplicitTruncationEvidence() throws {
    let timestamp = Date(timeIntervalSince1970: 20)
    let transitions = AgentLoopSnapshotTransitions(
        now: { timestamp },
        idGenerator: { "failure-event" },
        maximumFailureMessageUTF8Bytes: 4
    )
    let snapshot = SessionSnapshot(
        sessionID: "session-failure-bound",
        createdAt: timestamp,
        updatedAt: timestamp
    )

    let failed = try transitions.markingFailed(
        snapshot,
        error: AgentError.modelFailure("abcdef")
    ).snapshot

    #expect(failed.status == .failed)
    #expect(failed.failure?.message == "abcd")
    #expect(failed.failure?.details["messageTruncated"] == .bool(true))
    #expect(failed.failure?.details["originalMessageUTF8Bytes"] == .integer(6))
}
