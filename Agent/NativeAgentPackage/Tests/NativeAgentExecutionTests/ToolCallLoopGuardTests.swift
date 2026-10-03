import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentExecution

private func makeToolCall(id: String, value: String) -> ToolCall {
    ToolCall(id: id, name: "loop.echo", arguments: ["value": .string(value)])
}

private func toolResult(
    callID: String,
    content: String,
    isError: Bool = false
) -> AgentMessage {
    AgentMessage(
        id: "result-\(callID)",
        role: .tool,
        content: content,
        toolCallID: callID,
        toolName: "loop.echo",
        metadata: ["isError": .bool(isError), "output": .string(content)]
    )
}

@Test
func toolCallLoopGuardResetsAtTheLatestUserMessage() {
    let first = makeToolCall(id: "call-1", value: "same")
    let second = makeToolCall(id: "call-2", value: "same")
    let messages = [
        AgentMessage(role: .user, content: "first request"),
        AgentMessage(role: .assistant, content: "first", toolCalls: [first]),
        toolResult(callID: first.id, content: "stable"),
        AgentMessage(role: .assistant, content: "second", toolCalls: [second]),
        toolResult(callID: second.id, content: "stable"),
        AgentMessage(role: .user, content: "run it again"),
    ]
    let guardrail = ToolCallLoopGuard(messages: messages)

    #expect(guardrail.shouldBlock(makeToolCall(id: "call-3", value: "same")) == false)
}

@Test
func toolCallLoopGuardPermitsIdenticalPollingWhenResultsChange() {
    let first = makeToolCall(id: "call-1", value: "same")
    let second = makeToolCall(id: "call-2", value: "same")
    let messages = [
        AgentMessage(role: .user, content: "wait for completion"),
        AgentMessage(role: .assistant, content: "first", toolCalls: [first]),
        toolResult(callID: first.id, content: "queued"),
        AgentMessage(role: .assistant, content: "second", toolCalls: [second]),
        toolResult(callID: second.id, content: "running"),
    ]
    let guardrail = ToolCallLoopGuard(messages: messages)

    #expect(guardrail.shouldBlock(makeToolCall(id: "call-3", value: "same")) == false)
}

@Test
func toolCallLoopGuardBlocksOnlyRepeatedNoProgressWithinOneUserTurn() {
    let first = makeToolCall(id: "call-1", value: "same")
    let second = makeToolCall(id: "call-2", value: "same")
    let messages = [
        AgentMessage(role: .user, content: "lookup once"),
        AgentMessage(role: .assistant, content: "first", toolCalls: [first]),
        toolResult(callID: first.id, content: "not found", isError: true),
        AgentMessage(role: .assistant, content: "second", toolCalls: [second]),
        toolResult(callID: second.id, content: "not found", isError: true),
    ]
    let guardrail = ToolCallLoopGuard(messages: messages)

    #expect(guardrail.shouldBlock(makeToolCall(id: "call-3", value: "same")))
}
