import Foundation
import NativeAgentDomain

public struct ConsensusSelector: Sendable {
    private let closure: @Sendable (ModelRequest) throws -> ConsensusExecutionPlan?

    public init(_ closure: @escaping @Sendable (ModelRequest) throws -> ConsensusExecutionPlan?) {
        self.closure = closure
    }

    public func plan(for request: ModelRequest) throws -> ConsensusExecutionPlan? {
        try closure(request)
    }

    public static func metadataDriven() -> ConsensusSelector {
        ConsensusSelector { request in
            try ConsensusMetadata.executionPlan(from: request.metadata)
        }
    }
}

public struct ConsensusRunner: Sendable {
    public let triad: Triad
    public let baseConfig: BACConfig

    public init(triad: Triad, baseConfig: BACConfig = .init()) {
        self.triad = triad
        self.baseConfig = baseConfig
    }

    public init(triad: RoleBackedTriad, baseConfig: BACConfig = .init()) {
        self.init(triad: triad.triad, baseConfig: baseConfig)
    }

    public func run(
        problem: ProblemPacket,
        options: ConsensusRunOptions = .init()
    ) async throws -> BACResult {
        let config = BACConfig(
            maxRounds: options.maxRounds,
            maxRequiredSteps: options.maxRequiredSteps,
            registryQueryLimit: options.registryQueryLimit,
            registry: baseConfig.registry,
            gate: baseConfig.gate,
            synthesizer: baseConfig.synthesizer,
            observers: baseConfig.observers,
            now: baseConfig.now,
            runID: baseConfig.runID
        )
        let engine = try BACEngine(config: config, triad: triad)
        return try await engine.run(problem: problem)
    }
}

public struct ConsensusRoutingModelClient: ModelClient, Sendable {
    // Explicit consensus operations retain their existing aggregate contract. A routing
    // wrapper must not hide a forbidden request-decorating base client.
    public var invocationSemantics: ModelClientInvocationSemantics { base.invocationSemantics }
    public let providerID: String
    public var modelDescriptor: ModelDescriptor? { base.modelDescriptor }
    private let base: any ModelClient
    private let runner: ConsensusRunner
    private let selector: ConsensusSelector
    private let renderer: ConsensusResponseRenderer

    public init(
        base: any ModelClient,
        runner: ConsensusRunner,
        selector: ConsensusSelector = .metadataDriven(),
        renderer: ConsensusResponseRenderer = .concise
    ) {
        self.base = base
        self.runner = runner
        self.selector = selector
        self.renderer = renderer
        self.providerID = base.providerID
    }

    public func generate(request: ModelRequest) async throws -> ModelTurn {
        let plan = try selector.plan(for: request)
        try request.validateGenerationContract()
        if let descriptor = modelDescriptor {
            try request.validateSupportedCapabilities(descriptor.capabilities)
        }
        guard let plan else {
            return try await base.generate(request: request)
        }
        let turn = try await generateConsensus(plan: plan)
        try turn.validateGenerationContract(for: request)
        return turn
    }

    fileprivate func generateConsensus(plan: ConsensusExecutionPlan) async throws -> ModelTurn {
        let result = try await runner.run(problem: plan.problem, options: plan.options)
        let turnBuilder = ConsensusTurnBuilder(renderer: renderer)
        return try turnBuilder.makeTurn(from: result)
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        do {
            let plan = try selector.plan(for: request)
            try request.validateGenerationContract()
            if let descriptor = modelDescriptor {
                try request.validateSupportedCapabilities(descriptor.capabilities)
            }
            guard let plan else { return base.stream(request: request) }
            let state = ConsensusRoutingStreamState(plan: plan)
            return AsyncThrowingStream(unfolding: {
                try await state.next(client: self, request: request)
            })
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
    }
}

private actor ConsensusRoutingStreamState {
    private enum Phase {
        case started
        case completed
        case finished
    }

    private let plan: ConsensusExecutionPlan
    private var phase = Phase.started

    init(plan: ConsensusExecutionPlan) {
        self.plan = plan
    }

    func next(
        client: ConsensusRoutingModelClient,
        request: ModelRequest
    ) async throws -> ModelEvent? {
        try Task.checkCancellation()
        switch phase {
        case .started:
            phase = .completed
            return .started(descriptor: client.modelDescriptor)
        case .completed:
            phase = .finished
            let turn = try await client.generateConsensus(plan: plan)
            try turn.validateGenerationContract(for: request)
            return .completed(turn)
        case .finished:
            return nil
        }
    }
}
