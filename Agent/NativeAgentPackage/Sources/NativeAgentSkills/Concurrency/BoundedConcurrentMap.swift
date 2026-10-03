import NativeAgentDomain

func nativeAgentBoundedConcurrentMap<Input: Sendable, Output: Sendable>(
    _ inputs: [Input],
    maximumConcurrentTasks: Int,
    transform: @escaping @Sendable (Input) async throws -> Output
) async throws -> [Output] {
    guard inputs.isEmpty == false else { return [] }
    let taskLimit = max(1, min(maximumConcurrentTasks, inputs.count))

    return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var results = [Output?](repeating: nil, count: inputs.count)
        var nextIndex = 0

        while nextIndex < taskLimit {
            let index = nextIndex
            let input = inputs[index]
            group.addTask { (index, try await transform(input)) }
            nextIndex += 1
        }

        while let (index, output) = try await group.next() {
            results[index] = output
            if nextIndex < inputs.count {
                let index = nextIndex
                let input = inputs[index]
                group.addTask { (index, try await transform(input)) }
                nextIndex += 1
            }
        }

        return try results.enumerated().map { index, output in
            guard let output else {
                throw AgentError.invariantViolation(
                    "Bounded concurrent map did not produce output at index \(index)"
                )
            }
            return output
        }
    }
}
