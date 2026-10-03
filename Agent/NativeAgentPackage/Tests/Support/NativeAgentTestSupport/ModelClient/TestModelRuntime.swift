import Foundation
import NativeAgent
import NativeAgentDomain
import NativeAgentExecution
import LanguageModelRuntime
import NativeAgentStore

/// Test-only adapter from a `ModelClient` fixture to the production `ModelRuntime`.
public func makeTestModelRuntime(_ client: any ModelClient) throws -> ModelRuntime {
    let descriptor = client.modelDescriptor ?? ModelDescriptor(
        id: "test-model",
        providerID: client.providerID,
        capabilities: .allKnown,
        contextWindowTokens: 1_000_000
    )
    return try ModelRuntime(
        id: ModelRuntimeID(rawValue: "test.runtime"),
        client: client,
        descriptor: descriptor
    )
}

public extension Agent {
    init(
        model: any ModelClient,
        storage: AgentStorage,
        instructions: String? = nil,
        capabilities: [any AgentCapability] = [],
        toolPacks: [any ToolPack] = [],
        tools: [any ToolExecutor] = [],
        promptAugmentors: [any PromptAugmentor] = [],
        approval: AgentApproval = .denyAll,
        observer: (any RuntimeObserver)? = nil,
        configuration: AgentConfiguration = AgentConfiguration()
    ) throws {
        try self.init(
            modelRuntime: makeTestModelRuntime(model),
            storage: storage,
            instructions: instructions,
            capabilities: capabilities,
            toolPacks: toolPacks,
            tools: tools,
            promptAugmentors: promptAugmentors,
            approval: approval,
            observer: observer,
            configuration: configuration
        )
    }

    init(
        model: any ModelClient,
        appName: String,
        appGroupIdentifier: String? = nil,
        appGroupContainerURL: URL? = nil,
        storageSubdirectoryName: String = StoreLayout.defaultSubdirectoryName,
        executionClaimStore: (any SessionExecutionClaimStore)? = nil,
        instructions: String? = nil,
        capabilities: [any AgentCapability] = [],
        toolPacks: [any ToolPack] = [],
        tools: [any ToolExecutor] = [],
        promptAugmentors: [any PromptAugmentor] = [],
        approval: AgentApproval = .denyAll,
        observer: (any RuntimeObserver)? = nil,
        configuration: AgentConfiguration = AgentConfiguration()
    ) throws {
        try self.init(
            modelRuntime: makeTestModelRuntime(model),
            appName: appName,
            appGroupIdentifier: appGroupIdentifier,
            appGroupContainerURL: appGroupContainerURL,
            storageSubdirectoryName: storageSubdirectoryName,
            executionClaimStore: executionClaimStore,
            instructions: instructions,
            capabilities: capabilities,
            toolPacks: toolPacks,
            tools: tools,
            promptAugmentors: promptAugmentors,
            approval: approval,
            observer: observer,
            configuration: configuration
        )
    }
}

public extension SessionCoordinator {
    init(
        modelClient: any ModelClient,
        approvalRouter: any ApprovalRouter,
        runtimeStore: any SessionRuntimeStore,
        executionClaimStore: (any SessionExecutionClaimStore)? = nil,
        toolPacks: [any ToolPack],
        configuration: RuntimeConfiguration = RuntimeConfiguration(),
        promptAugmentor: any PromptAugmentor = InstructionAssemblyPromptAugmentor(),
        compactor: ContextWindowCompactor = ContextWindowCompactor(),
        observer: (any RuntimeObserver)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) throws {
        try self.init(
            modelRuntime: makeTestModelRuntime(modelClient),
            approvalRouter: approvalRouter,
            runtimeStore: runtimeStore,
            executionClaimStore: executionClaimStore,
            toolPacks: toolPacks,
            configuration: configuration,
            promptAugmentor: promptAugmentor,
            compactor: compactor,
            observer: observer,
            now: now,
            idGenerator: idGenerator
        )
    }
}
