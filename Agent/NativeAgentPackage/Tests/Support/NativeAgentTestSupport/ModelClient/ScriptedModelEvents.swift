import Foundation
import LanguageModelCore

public func scriptedModelEvents(
    descriptor: ModelDescriptor?,
    generate: @escaping @Sendable () async throws -> ModelTurn
) -> AsyncThrowingStream<ModelEvent, any Error> {
    let sequence = ScriptedEventSequence(descriptor: descriptor, generate: generate)
    return AsyncThrowingStream(unfolding: { try await sequence.next() })
}

private actor ScriptedEventSequence {
    let descriptor: ModelDescriptor?
    let generate: @Sendable () async throws -> ModelTurn
    var phase = 0
    init(descriptor: ModelDescriptor?, generate: @escaping @Sendable () async throws -> ModelTurn) {
        self.descriptor = descriptor; self.generate = generate
    }
    func next() async throws -> ModelEvent? {
        try Task.checkCancellation()
        switch phase {
        case 0: phase = 1; return .started(descriptor: descriptor)
        case 1: phase = 2; return .completed(try await generate())
        default: return nil
        }
    }
}
