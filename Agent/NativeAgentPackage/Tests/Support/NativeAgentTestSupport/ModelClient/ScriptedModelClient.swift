import Foundation
import NativeAgentDomain

public actor ScriptedModelClient: ModelClient {
    public let providerID: String
    public nonisolated let modelDescriptor: ModelDescriptor?
    private var scriptedTurns: [ModelTurn]
    private var currentIndex: Int
    private var requests: [ModelRequest]

    public init(
        providerID: String = "provider.test.scripted",
        modelDescriptor: ModelDescriptor? = nil,
        scriptedTurns: [ModelTurn] = []
    ) {
        self.providerID = providerID
        self.modelDescriptor = modelDescriptor
        self.scriptedTurns = scriptedTurns
        self.currentIndex = 0
        self.requests = []
    }

    public func enqueue(_ turn: ModelTurn) {
        scriptedTurns.append(turn)
    }

    public func generate(request: ModelRequest) async throws -> ModelTurn {
        requests.append(request)
        guard !scriptedTurns.isEmpty else {
            return ModelTurn(content: "No scripted turn configured.")
        }

        guard currentIndex < scriptedTurns.count else {
            throw AgentError.unavailableProvider("All scripted turns exhausted.")
        }

        let turn = scriptedTurns[currentIndex]
        currentIndex += 1
        return turn
    }

    public func callCount() -> Int {
        currentIndex
    }

    public func recordedRequests() -> [ModelRequest] {
        requests
    }
}
