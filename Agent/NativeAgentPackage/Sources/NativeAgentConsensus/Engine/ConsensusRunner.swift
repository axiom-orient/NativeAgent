public protocol RunnerProtocol<ResultValue>: Sendable {
    associatedtype ResultValue
    func run(problem: ProblemPacket) async throws -> ResultValue
}
