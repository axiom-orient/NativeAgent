import Testing
@testable import NativeAgentDomain
import NativeAgentTestSupport

@Test
func scriptedModelClientReturnsScriptedTurnsInOrder() async throws {
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "a"),
        ModelTurn(content: "b")
    ])

    let request = ModelRequest(sessionID: "s1", messages: [], tools: [])
    let first = try await provider.generate(request: request)
    let second = try await provider.generate(request: request)

    #expect(first.content == "a")
    #expect(second.content == "b")
    let count = await provider.callCount()
    #expect(count == 2)
}

@Test
func scriptedModelClientFailsWhenScriptedTurnsAreExhausted() async throws {
    let provider = ScriptedModelClient(scriptedTurns: [
        ModelTurn(content: "only")
    ])

    let request = ModelRequest(sessionID: "s1", messages: [], tools: [])
    let first = try await provider.generate(request: request)
    #expect(first.content == "only")

    await #expect(throws: AgentError.self) {
        _ = try await provider.generate(request: request)
    }

    let count = await provider.callCount()
    #expect(count == 1)
}
