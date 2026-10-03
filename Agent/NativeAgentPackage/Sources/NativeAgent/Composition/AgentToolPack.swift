import NativeAgentDomain

struct AgentToolPack: ToolPack {
    let packID = "native-agent.agent.application-tools"
    let tools: [any ToolExecutor]

    func executors() -> [any ToolExecutor] {
        tools
    }
}
