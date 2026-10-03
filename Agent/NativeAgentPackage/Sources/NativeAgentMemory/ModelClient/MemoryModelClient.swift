import NativeAgentDomain
import Foundation

/// Standalone request decorator; ModelRuntime rejects this composition before memory/provider invocation.
/// Memory performs only pre-provider projection
/// work and forwards the base provider's result/events without post-response
/// capture, metadata rewriting, or consolidation.
public struct MemoryModelClient: ModelClient {
    public var invocationSemantics: ModelClientInvocationSemantics { .standaloneOnly }
    public let providerID: String
    public var modelDescriptor: ModelDescriptor? { base.modelDescriptor }

    private let base: any ModelClient
    private let memory: MemoryController
    private let transcriptSource: any MemoryTranscriptSource
    private let configuration: MemoryConfiguration

    public init(
        base: any ModelClient,
        memory: MemoryController,
        transcriptSource: any MemoryTranscriptSource
    ) {
        self.base = base
        self.memory = memory
        self.transcriptSource = transcriptSource
        self.configuration = memory.configuration
        self.providerID = base.providerID
    }

    public func generate(request: ModelRequest) async throws -> ModelTurn {
        try Task.checkCancellation()
        try request.validateGenerationContract()
        if let descriptor = modelDescriptor {
            try request.validateSupportedCapabilities(descriptor.capabilities)
        }
        guard MemoryRequestPlanner.memoryDisabled(in: request) == false else {
            return try await base.generate(request: request)
        }
        let prepared = try await prepare(request: request)
        try Task.checkCancellation()
        // The provider is now the sole owner of this invocation's result.
        return try await base.generate(request: prepared)
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        guard MemoryRequestPlanner.memoryDisabled(in: request) == false else {
            return base.stream(request: request)
        }
        let state = MemoryModelStreamState(client: self, request: request)
        return AsyncThrowingStream(unfolding: { try await state.next() })
    }

    private func prepare(request: ModelRequest) async throws -> ModelRequest {
        try Task.checkCancellation()
        let plan = MemoryRequestPlanner.makePlan(
            request: request,
            defaultProfileID: configuration.defaultProfileID,
            defaultUserID: configuration.defaultUserID,
            defaultNamespace: configuration.namespace
        )
        // Sync and recall share the exact same resolved scope. The source
        // session remains provenance; the plan scope is the retrieval boundary.
        _ = try await memory.sync(scope: plan.scope, sessionID: request.sessionID, from: transcriptSource)
        try Task.checkCancellation()
        guard MemoryRequestPlanner.contextDisabled(in: request) == false,
              let query = plan.query else {
            return request
        }
        let currentMessageIDs = Set(
            request.messages.reversed().first(where: { $0.role == .user }).map { [$0.id] } ?? []
        )
        let context = try await memory.recall(
            scope: plan.scope,
            query: query,
            maxResults: configuration.maxContextResults,
            excludingMessageIDs: currentMessageIDs
        )
        try Task.checkCancellation()
        guard context.isEmpty == false else { return request }
        return MemoryRequestPlanner.augment(
            request: request,
            with: context,
            createdAt: DeterministicCoreDefaults.timestamp
        )
    }
}

/// AsyncStream's unfolding initializer keeps preparation and base iteration in
/// the consumer's structured task. No detached or unstructured producer task
/// can outlive the caller or reorder model events.
private actor MemoryModelStreamState {
    private let client: MemoryModelClient
    private let request: ModelRequest
    private var baseStream: AsyncThrowingStream<ModelEvent, any Error>?
    private var finished = false

    init(client: MemoryModelClient, request: ModelRequest) {
        self.client = client
        self.request = request
    }

    func next() async throws -> ModelEvent? {
        try Task.checkCancellation()
        guard !finished else { return nil }
        if baseStream == nil {
            baseStream = try await client.preparedBaseStream(for: request)
        }
        guard let baseStream else { return nil }
        var iterator = baseStream.makeAsyncIterator()
        let event = try await iterator.next()
        try Task.checkCancellation()
        if event == nil { finished = true }
        return event
    }
}

private extension MemoryModelClient {
    func preparedBaseStream(for request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, any Error> {
        let prepared = try await prepare(request: request)
        try Task.checkCancellation()
        return base.stream(request: prepared)
    }
}
