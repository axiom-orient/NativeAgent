import Foundation
import NativeAgentDomain
import LanguageModelRuntime

public actor SessionCoordinator {
    let modelRuntime: ModelRuntime
    let approvalRouter: any ApprovalRouter
    let store: any SessionRuntimeStore
    let registry: ToolRegistry
    let executionClaimStore: (any SessionExecutionClaimStore)?
    let configuration: RuntimeConfiguration
    let resourceValidator: RuntimeResourceValidator
    let promptAugmentor: any PromptAugmentor
    let turnPromptAugmentor: (any PromptAugmentor)?
    let compactor: ContextWindowCompactor
    let observer: (any RuntimeObserver)?
    let now: @Sendable () -> Date
    let idGenerator: @Sendable () -> String
    let journal: SessionJournal
    let snapshotWriter: RuntimeSnapshotWriter
    let toolErrorAppender: RuntimeToolErrorAppender
    let executionAuthority: SessionExecutionAuthority

    /// Canonical construction. The caller passes a SessionRuntimeStore directly.
    public init(
        modelRuntime: ModelRuntime,
        approvalRouter: any ApprovalRouter,
        runtimeStore: any SessionRuntimeStore,
        executionClaimStore: (any SessionExecutionClaimStore)? = nil,
        toolPacks: [any ToolPack],
        configuration: RuntimeConfiguration = RuntimeConfiguration(),
        promptAugmentor: any PromptAugmentor = InstructionAssemblyPromptAugmentor(),
        turnPromptAugmentor: (any PromptAugmentor)? = nil,
        compactor: ContextWindowCompactor = ContextWindowCompactor(),
        observer: (any RuntimeObserver)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) throws {
        try self.init(
            modelRuntime: modelRuntime,
            approvalRouter: approvalRouter,
            runtimeStore: runtimeStore,
            executionClaimStore: executionClaimStore,
            executionAuthority: SessionExecutionAuthority(),
            toolPacks: toolPacks,
            configuration: configuration,
            promptAugmentor: promptAugmentor,
            turnPromptAugmentor: turnPromptAugmentor,
            compactor: compactor,
            observer: observer,
            now: now,
            idGenerator: idGenerator
        )
    }

    /// Package construction used by `AgentStorage` so separately assembled `Agent` facades share
    /// execution admission and pending claim-release state without moving durable session authority into the manager.
    package init(
        modelRuntime: ModelRuntime,
        approvalRouter: any ApprovalRouter,
        runtimeStore: any SessionRuntimeStore,
        executionClaimStore: (any SessionExecutionClaimStore)? = nil,
        executionAuthority: SessionExecutionAuthority,
        toolPacks: [any ToolPack],
        configuration: RuntimeConfiguration = RuntimeConfiguration(),
        promptAugmentor: any PromptAugmentor = InstructionAssemblyPromptAugmentor(),
        turnPromptAugmentor: (any PromptAugmentor)? = nil,
        compactor: ContextWindowCompactor = ContextWindowCompactor(),
        observer: (any RuntimeObserver)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) throws {
        let registry = try ToolRegistry(toolPacks: toolPacks)
        if !registry.definitions.isEmpty, !modelRuntime.capabilities.contains(.toolCalls) {
            throw AgentError.invalidConfiguration(
                "Registered tools require a model runtime that advertises toolCalls capability."
            )
        }
        let resolvedExecutionClaimStore =
            executionClaimStore ?? (runtimeStore as? any SessionExecutionClaimStore)
        try configuration.validate(
            toolDefinitions: registry.definitions,
            executionClaimStore: resolvedExecutionClaimStore
        )

        let persistedClock = PersistedTimestamp.clock(now)

        self.modelRuntime = modelRuntime
        self.approvalRouter = approvalRouter
        self.store = runtimeStore
        self.registry = registry
        self.executionClaimStore = resolvedExecutionClaimStore
        let resourceValidator = RuntimeResourceValidator(limits: configuration.resourceLimits)
        try resourceValidator.validate(toolDefinitions: registry.definitions)
        self.configuration = configuration
        self.resourceValidator = resourceValidator
        self.promptAugmentor = promptAugmentor
        self.turnPromptAugmentor = turnPromptAugmentor
        self.compactor = compactor
        self.observer = observer
        self.now = persistedClock
        self.idGenerator = idGenerator
        self.journal = SessionJournal(now: persistedClock, idGenerator: idGenerator)
        self.snapshotWriter = RuntimeSnapshotWriter(
            journal: self.journal,
            resourceValidator: resourceValidator,
            transactionalStore: runtimeStore
        )
        self.toolErrorAppender = RuntimeToolErrorAppender(
            writer: self.snapshotWriter,
            transitions: AgentLoopSnapshotTransitions(
                now: persistedClock,
                idGenerator: idGenerator,
                maximumFailureMessageUTF8Bytes: configuration.resourceLimits.maxFailureMessageUTF8Bytes
            )
        )
        self.executionAuthority = executionAuthority
    }

    public func availableTools() -> [ToolDefinition] { registry.definitions }

    public func discoverTools(intent: String, limit: Int = 8) throws -> [ToolCapabilitySummary] {
        try registry.discover(intent: intent, limit: limit)
    }

    public func toolContract(named name: String) -> ToolDefinition? {
        registry.contract(named: name)
    }

    /// Returns the durable receipt for one mutating tool operation identity.
    /// Read-only tools intentionally have no effect-ledger record.
    public func toolEffect(sessionID: String, callID: String) async throws -> EffectRecord? {
        let normalized = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw AgentError.invalidToolCall("Tool effect callID must not be empty.")
        }
        return try await store.loadEffect(
            sessionID: sessionID,
            scope: .toolCall,
            key: normalized
        )
    }
}
