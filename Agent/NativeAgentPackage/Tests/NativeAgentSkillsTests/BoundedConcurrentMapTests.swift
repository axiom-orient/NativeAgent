import Testing

@testable import NativeAgentSkills

private actor ConcurrentOperationProbe {
    private var active = 0
    private var maximumActive = 0

    func begin() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() {
        active -= 1
    }

    func peak() -> Int {
        maximumActive
    }
}

@Test
func boundedConcurrentMapPreservesOrderAndLimitsTaskFanOut() async throws {
    let probe = ConcurrentOperationProbe()
    let values = Array(0..<24)

    let outputs = try await nativeAgentBoundedConcurrentMap(
        values,
        maximumConcurrentTasks: 3
    ) { value in
        await probe.begin()
        try await Task.sleep(for: .milliseconds(5))
        await probe.end()
        return value * 2
    }

    #expect(outputs == values.map { $0 * 2 })
    #expect(await probe.peak() <= 3)
}
