import Foundation
import NativeAgentDomain

struct ConsensusTurnBuilder: Sendable {
    let renderer: ConsensusResponseRenderer

    init(renderer: ConsensusResponseRenderer) {
        self.renderer = renderer
    }

    func makeTurn(from result: BACResult) throws -> ModelTurn {
        let metadata = try ConsensusMetadata.resultMetadata(result)
        return ModelTurn(
            content: renderer.render(result),
            metadata: metadata
        )
    }
}
