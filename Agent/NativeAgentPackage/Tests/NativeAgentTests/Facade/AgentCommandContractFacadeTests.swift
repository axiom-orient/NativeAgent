import Foundation
import Testing
import NativeAgent

@Test
func durableCommandContractsAreAvailableFromAgentFacade() throws {
    let identity = AgentCommandIdentity(
        operationID: "facade.operation",
        expectedRevision: 7
    )
    let receipt = AgentCommandReceipt(
        operationID: identity.operationID,
        sessionID: "session",
        revision: 8
    )

    #expect(identity.operationID == receipt.operationID)
    #expect(receipt.revision == identity.expectedRevision + 1)
    #expect(
        try JSONDecoder().decode(
            AgentCommandIdentity.self,
            from: JSONEncoder().encode(identity)
        ) == identity
    )
    #expect(
        try JSONDecoder().decode(
            AgentCommandReceipt.self,
            from: JSONEncoder().encode(receipt)
        ) == receipt
    )
}
