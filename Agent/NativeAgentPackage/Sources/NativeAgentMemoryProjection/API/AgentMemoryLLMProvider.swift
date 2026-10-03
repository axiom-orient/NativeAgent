import Foundation

package struct AgentMemoryGenerateMessage: Sendable, Equatable {
    package let role: String
    package let content: String

    package init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

package struct AgentMemoryGenerateRequest: Sendable, Equatable {
    package let system: String
    package let messages: [AgentMemoryGenerateMessage]

    package init(system: String = "", messages: [AgentMemoryGenerateMessage]) {
        self.system = system
        self.messages = messages
    }
}

package struct AgentMemoryGenerateResponse: Sendable, Equatable {
    package let content: String

    package init(content: String) {
        self.content = content
    }
}

package protocol AgentMemoryLLMProvider: Sendable {
    func generate(_ request: AgentMemoryGenerateRequest) async throws -> AgentMemoryGenerateResponse
}
