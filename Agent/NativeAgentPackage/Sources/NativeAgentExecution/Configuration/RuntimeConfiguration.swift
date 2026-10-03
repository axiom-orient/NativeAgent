import Foundation
import NativeAgentDomain

public struct ContextBudgetPolicy: Sendable, Equatable {
    /// Configuration sanity bound for a model context window. It accommodates
    /// current long-context models while rejecting corrupt provider metadata.
    public static let supportedMaximumWindowTokens = 16_000_000
    public static let supportedMaximumRecentMessages = 10_000
    public static let supportedMaximumSummaryCharacters = 1 * 1_024 * 1_024

    public static let standardTriggerRatio = 0.65
    public static let standardTargetRatio = 0.45
    public static let standardKeepRecentMessages = 8
    public static let standardMaxSummaryCharacters = 2_400
    public static let mobileWindowTokens = 32_000
    public static let mobileReservedOutputTokens = 4_096
    public static let mobileTriggerRatio = 0.70
    public static let mobileTargetRatio = 0.50
    public static let mobileKeepRecentMessages = 24
    public static let mobileMaxSummaryCharacters = 8_000

    private static let maximumDefaultReservedOutputTokens = 4_096
    private static let defaultReservedOutputDivisor = 8

    /// Total context capacity advertised by the model, including output.
    public let windowTokens: Int
    /// Capacity reserved for the next model answer or tool call.
    public let reservedOutputTokens: Int
    public let triggerRatio: Double
    public let targetRatio: Double
    public let keepRecentMessages: Int
    public let maxSummaryCharacters: Int
    public let preserveSystemMessages: Bool

    public init(
        windowTokens: Int,
        reservedOutputTokens: Int? = nil,
        triggerRatio: Double = Self.standardTriggerRatio,
        targetRatio: Double = Self.standardTargetRatio,
        keepRecentMessages: Int = Self.standardKeepRecentMessages,
        maxSummaryCharacters: Int = Self.standardMaxSummaryCharacters,
        preserveSystemMessages: Bool = true
    ) {
        self.windowTokens = windowTokens
        self.reservedOutputTokens = reservedOutputTokens
            ?? Self.defaultReservedOutputTokens(for: windowTokens)
        self.triggerRatio = triggerRatio
        self.targetRatio = targetRatio
        self.keepRecentMessages = keepRecentMessages
        self.maxSummaryCharacters = maxSummaryCharacters
        self.preserveSystemMessages = preserveSystemMessages
    }

    /// Maximum input capacity after the output reservation.
    public var inputWindowTokens: Int {
        max(1, windowTokens - reservedOutputTokens)
    }

    public var triggerTokens: Int {
        max(1, Int(Double(inputWindowTokens) * triggerRatio))
    }

    public var targetTokens: Int {
        max(1, Int(Double(inputWindowTokens) * targetRatio))
    }

    /// Conservative default for an iOS host. Providers with a larger verified
    /// context window can opt in to a different explicit policy.
    public static let mobileDefault = ContextBudgetPolicy(
        windowTokens: mobileWindowTokens,
        reservedOutputTokens: mobileReservedOutputTokens,
        triggerRatio: mobileTriggerRatio,
        targetRatio: mobileTargetRatio,
        keepRecentMessages: mobileKeepRecentMessages,
        maxSummaryCharacters: mobileMaxSummaryCharacters,
        preserveSystemMessages: true
    )

    private static func defaultReservedOutputTokens(for windowTokens: Int) -> Int {
        guard windowTokens > 1 else { return 0 }
        return min(
            maximumDefaultReservedOutputTokens,
            max(1, windowTokens / defaultReservedOutputDivisor)
        )
    }
}

public enum SessionExecutionSafety: String, Sendable, Equatable {
    /// In-process admission only. Agent facades and recovery sharing one AgentStorage
    /// share one reservation owner. Separately constructed storage/coordinators and
    /// other processes require sharedClaimRequired for mutual exclusion.
    case coordinatorOnly
    /// A shared SessionExecutionClaimStore must own every advancing session.
    case sharedClaimRequired
}

public struct RuntimeSafetyPolicy: Sendable, Equatable {
    public let sessionExecution: SessionExecutionSafety

    public init(
        sessionExecution: SessionExecutionSafety = .sharedClaimRequired
    ) {
        self.sessionExecution = sessionExecution
    }

    /// Fail-closed policy for durable execution and restart recovery.
    public static let durable = RuntimeSafetyPolicy(
        sessionExecution: .sharedClaimRequired
    )
}

public struct RuntimeJSONStructureLimits: Sendable, Equatable {
    public static let standardMaxDepth = 64
    public static let standardMaxNodes = 100_000
    public static let standardMaxCollectionEntries = 20_000
    public static let standardMaxStringUTF8Bytes = 2 * 1_024 * 1_024
    public static let standardMaxKeyUTF8Bytes = 1_024
    public static let standardMaxTotalStringUTF8Bytes = 16 * 1_024 * 1_024

    public let maxDepth: Int
    public let maxNodes: Int
    public let maxCollectionEntries: Int
    public let maxStringUTF8Bytes: Int
    public let maxKeyUTF8Bytes: Int
    public let maxTotalStringUTF8Bytes: Int

    public init(
        maxDepth: Int = Self.standardMaxDepth,
        maxNodes: Int = Self.standardMaxNodes,
        maxCollectionEntries: Int = Self.standardMaxCollectionEntries,
        maxStringUTF8Bytes: Int = Self.standardMaxStringUTF8Bytes,
        maxKeyUTF8Bytes: Int = Self.standardMaxKeyUTF8Bytes,
        maxTotalStringUTF8Bytes: Int = Self.standardMaxTotalStringUTF8Bytes
    ) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxCollectionEntries = maxCollectionEntries
        self.maxStringUTF8Bytes = maxStringUTF8Bytes
        self.maxKeyUTF8Bytes = maxKeyUTF8Bytes
        self.maxTotalStringUTF8Bytes = maxTotalStringUTF8Bytes
    }

    public static let standard = RuntimeJSONStructureLimits()
}

public struct RuntimeResourceLimits: Sendable, Equatable {
    public static let standardMaxSessionArtifacts = 10_000
    public static let standardMaxSessionArtifactBytes = 512 * 1_024 * 1_024
    public static let standardMaxToolCount = ModelToolContract.maximumDefinitionCount
    public static let standardMaxToolCallsPerTurn = ModelToolContract.maximumCallsPerTurn
    public static let standardMaxTranscriptMessages = 20_000
    public static let standardMaxSessionHydrationPayloadBytes = 128 * 1_024 * 1_024
    public static let standardMaxMessageUTF8Bytes = 2 * 1_024 * 1_024
    public static let standardMaxIdentifierUTF8Bytes = 4 * 1_024
    public static let standardMaxFailureMessageUTF8Bytes = 64 * 1_024
    public static let standardMaxToolArgumentsUTF8Bytes = 1 * 1_024 * 1_024
    public static let standardMaxArtifactsPerToolResult = 64
    public static let standardMaxArtifactBytes = 32 * 1_024 * 1_024

    public static let supportedMaximumIterations = 256
    public static let supportedMaximumToolCount = ModelToolContract.maximumDefinitionCount
    public static let supportedMaximumToolCallsPerTurn = ModelToolContract.maximumCallsPerTurn
    public static let supportedMaximumTranscriptMessages = 100_000
    public static let supportedMaximumSessionHydrationPayloadBytes = 2 * 1_024 * 1_024 * 1_024
    public static let supportedMaximumMessageUTF8Bytes = 16 * 1_024 * 1_024
    public static let supportedMaximumIdentifierUTF8Bytes = 64 * 1_024
    public static let supportedMaximumFailureMessageUTF8Bytes = 1 * 1_024 * 1_024
    public static let supportedMaximumToolArgumentsUTF8Bytes = 8 * 1_024 * 1_024
    public static let supportedMaximumSessionArtifacts = 100_000
    public static let supportedMaximumSessionArtifactBytes = 8 * 1_024 * 1_024 * 1_024
    public static let supportedMaximumArtifactsPerToolResult = 1_024
    public static let supportedMaximumArtifactBytes = 512 * 1_024 * 1_024
    public static let supportedMaximumJSONDepth = 256
    public static let supportedMaximumJSONNodes = 1_000_000
    public static let supportedMaximumJSONCollectionEntries = 100_000
    public static let supportedMaximumJSONStringUTF8Bytes = 16 * 1_024 * 1_024
    public static let supportedMaximumJSONKeyUTF8Bytes = 64 * 1_024
    public static let supportedMaximumJSONTotalStringUTF8Bytes = 64 * 1_024 * 1_024

    public let maxToolCount: Int
    public let maxToolCallsPerTurn: Int
    public let maxTranscriptMessages: Int
    public let maxSessionHydrationPayloadBytes: Int
    public let maxMessageUTF8Bytes: Int
    public let maxIdentifierUTF8Bytes: Int
    public let maxFailureMessageUTF8Bytes: Int
    public let maxToolArgumentsUTF8Bytes: Int
    public let maxSessionArtifacts: Int
    public let maxSessionArtifactBytes: Int
    public let maxArtifactsPerToolResult: Int
    public let maxArtifactBytes: Int
    public let maxJSONDepth: Int
    public let maxJSONNodes: Int
    public let maxJSONCollectionEntries: Int
    public let maxJSONStringUTF8Bytes: Int
    public let maxJSONKeyUTF8Bytes: Int
    public let maxJSONTotalStringUTF8Bytes: Int

    /// Limits for untrusted JSON, transcript growth, and cumulative artifacts.
    public init(
        jsonStructureLimits: RuntimeJSONStructureLimits = .standard,
        maxSessionArtifacts: Int = Self.standardMaxSessionArtifacts,
        maxSessionArtifactBytes: Int = Self.standardMaxSessionArtifactBytes,
        maxToolCount: Int = Self.standardMaxToolCount,
        maxToolCallsPerTurn: Int = Self.standardMaxToolCallsPerTurn,
        maxTranscriptMessages: Int = Self.standardMaxTranscriptMessages,
        maxSessionHydrationPayloadBytes: Int = Self.standardMaxSessionHydrationPayloadBytes,
        maxMessageUTF8Bytes: Int = Self.standardMaxMessageUTF8Bytes,
        maxIdentifierUTF8Bytes: Int = Self.standardMaxIdentifierUTF8Bytes,
        maxFailureMessageUTF8Bytes: Int = Self.standardMaxFailureMessageUTF8Bytes,
        maxToolArgumentsUTF8Bytes: Int = Self.standardMaxToolArgumentsUTF8Bytes,
        maxArtifactsPerToolResult: Int = Self.standardMaxArtifactsPerToolResult,
        maxArtifactBytes: Int = Self.standardMaxArtifactBytes
    ) {
        self.maxToolCount = maxToolCount
        self.maxToolCallsPerTurn = maxToolCallsPerTurn
        self.maxTranscriptMessages = maxTranscriptMessages
        self.maxSessionHydrationPayloadBytes = maxSessionHydrationPayloadBytes
        self.maxMessageUTF8Bytes = maxMessageUTF8Bytes
        self.maxIdentifierUTF8Bytes = maxIdentifierUTF8Bytes
        self.maxFailureMessageUTF8Bytes = maxFailureMessageUTF8Bytes
        self.maxToolArgumentsUTF8Bytes = maxToolArgumentsUTF8Bytes
        self.maxSessionArtifacts = maxSessionArtifacts
        self.maxSessionArtifactBytes = maxSessionArtifactBytes
        self.maxArtifactsPerToolResult = maxArtifactsPerToolResult
        self.maxArtifactBytes = maxArtifactBytes
        self.maxJSONDepth = jsonStructureLimits.maxDepth
        self.maxJSONNodes = jsonStructureLimits.maxNodes
        self.maxJSONCollectionEntries = jsonStructureLimits.maxCollectionEntries
        self.maxJSONStringUTF8Bytes = jsonStructureLimits.maxStringUTF8Bytes
        self.maxJSONKeyUTF8Bytes = jsonStructureLimits.maxKeyUTF8Bytes
        self.maxJSONTotalStringUTF8Bytes = jsonStructureLimits.maxTotalStringUTF8Bytes
    }
}

public struct RuntimeConfiguration: Sendable, Equatable {
    public let maxIterations: Int
    public let contextBudgetPolicy: ContextBudgetPolicy?
    public let safetyPolicy: RuntimeSafetyPolicy
    public let resourceLimits: RuntimeResourceLimits
    public let outputFormat: ModelOutputFormat

    public init(
        // A last-resort containment bound for one agent advancement. Durable
        // conversation length is not limited by this value.
        maxIterations: Int = RuntimeResourceLimits.supportedMaximumIterations,
        contextBudgetPolicy: ContextBudgetPolicy? = .mobileDefault,
        safetyPolicy: RuntimeSafetyPolicy = RuntimeSafetyPolicy(),
        resourceLimits: RuntimeResourceLimits = RuntimeResourceLimits(),
        outputFormat: ModelOutputFormat = .text
    ) {
        self.maxIterations = maxIterations
        self.contextBudgetPolicy = contextBudgetPolicy
        self.safetyPolicy = safetyPolicy
        self.resourceLimits = resourceLimits
        self.outputFormat = outputFormat
    }

    func validate(
        toolDefinitions: [ToolDefinition],
        executionClaimStore: (any SessionExecutionClaimStore)?
    ) throws {
        try validateValues(toolDefinitions: toolDefinitions)
        if safetyPolicy.sessionExecution == .sharedClaimRequired,
           executionClaimStore == nil {
            throw AgentError.invalidConfiguration(
                "RuntimeSafetyPolicy requires a shared SessionExecutionClaimStore."
            )
        }
    }

    private func validateValues(toolDefinitions: [ToolDefinition]) throws {
        try outputFormat.validate()
        if case .jsonObject = outputFormat, !toolDefinitions.isEmpty {
            throw AgentError.invalidConfiguration("Structured Agent output currently requires a tool-free Agent.")
        }
        guard (1...RuntimeResourceLimits.supportedMaximumIterations).contains(maxIterations) else {
            throw AgentError.invalidConfiguration(
                "maxIterations must be between 1 and \(RuntimeResourceLimits.supportedMaximumIterations)."
            )
        }

        try validate(resourceLimits.maxToolCount, name: "maxToolCount", maximum: RuntimeResourceLimits.supportedMaximumToolCount)
        try validate(resourceLimits.maxToolCallsPerTurn, name: "maxToolCallsPerTurn", maximum: RuntimeResourceLimits.supportedMaximumToolCallsPerTurn)
        try validate(resourceLimits.maxTranscriptMessages, name: "maxTranscriptMessages", maximum: RuntimeResourceLimits.supportedMaximumTranscriptMessages)
        try validate(resourceLimits.maxSessionHydrationPayloadBytes, name: "maxSessionHydrationPayloadBytes", maximum: RuntimeResourceLimits.supportedMaximumSessionHydrationPayloadBytes)
        try validate(resourceLimits.maxMessageUTF8Bytes, name: "maxMessageUTF8Bytes", maximum: RuntimeResourceLimits.supportedMaximumMessageUTF8Bytes)
        try validate(resourceLimits.maxIdentifierUTF8Bytes, name: "maxIdentifierUTF8Bytes", maximum: RuntimeResourceLimits.supportedMaximumIdentifierUTF8Bytes)
        try validate(resourceLimits.maxFailureMessageUTF8Bytes, name: "maxFailureMessageUTF8Bytes", maximum: RuntimeResourceLimits.supportedMaximumFailureMessageUTF8Bytes)
        try validate(resourceLimits.maxToolArgumentsUTF8Bytes, name: "maxToolArgumentsUTF8Bytes", maximum: RuntimeResourceLimits.supportedMaximumToolArgumentsUTF8Bytes)
        try validate(resourceLimits.maxSessionArtifacts, name: "maxSessionArtifacts", maximum: RuntimeResourceLimits.supportedMaximumSessionArtifacts)
        try validate(resourceLimits.maxSessionArtifactBytes, name: "maxSessionArtifactBytes", maximum: RuntimeResourceLimits.supportedMaximumSessionArtifactBytes)
        try validate(resourceLimits.maxArtifactsPerToolResult, name: "maxArtifactsPerToolResult", maximum: RuntimeResourceLimits.supportedMaximumArtifactsPerToolResult)
        try validate(resourceLimits.maxArtifactBytes, name: "maxArtifactBytes", maximum: RuntimeResourceLimits.supportedMaximumArtifactBytes)
        try validate(resourceLimits.maxJSONDepth, name: "maxJSONDepth", maximum: RuntimeResourceLimits.supportedMaximumJSONDepth)
        try validate(resourceLimits.maxJSONNodes, name: "maxJSONNodes", maximum: RuntimeResourceLimits.supportedMaximumJSONNodes)
        try validate(resourceLimits.maxJSONCollectionEntries, name: "maxJSONCollectionEntries", maximum: RuntimeResourceLimits.supportedMaximumJSONCollectionEntries)
        try validate(resourceLimits.maxJSONStringUTF8Bytes, name: "maxJSONStringUTF8Bytes", maximum: RuntimeResourceLimits.supportedMaximumJSONStringUTF8Bytes)
        try validate(resourceLimits.maxJSONKeyUTF8Bytes, name: "maxJSONKeyUTF8Bytes", maximum: RuntimeResourceLimits.supportedMaximumJSONKeyUTF8Bytes)
        try validate(resourceLimits.maxJSONTotalStringUTF8Bytes, name: "maxJSONTotalStringUTF8Bytes", maximum: RuntimeResourceLimits.supportedMaximumJSONTotalStringUTF8Bytes)

        guard toolDefinitions.count <= resourceLimits.maxToolCount else {
            throw AgentError.invalidConfiguration(
                "Configured tool count \(toolDefinitions.count) exceeds maxToolCount \(resourceLimits.maxToolCount)."
            )
        }

        if let contextBudgetPolicy {
            guard (1...ContextBudgetPolicy.supportedMaximumWindowTokens)
                .contains(contextBudgetPolicy.windowTokens) else {
                throw AgentError.invalidConfiguration(
                    "Context windowTokens must be between 1 and \(ContextBudgetPolicy.supportedMaximumWindowTokens)."
                )
            }
            guard contextBudgetPolicy.targetRatio > 0,
                  contextBudgetPolicy.triggerRatio > contextBudgetPolicy.targetRatio,
                  contextBudgetPolicy.triggerRatio <= 1 else {
                throw AgentError.invalidConfiguration(
                    "Context ratios must satisfy 0 < targetRatio < triggerRatio <= 1."
                )
            }
            guard contextBudgetPolicy.reservedOutputTokens >= 0,
                  contextBudgetPolicy.reservedOutputTokens < contextBudgetPolicy.windowTokens else {
                throw AgentError.invalidConfiguration(
                    "Context reservedOutputTokens must be non-negative and smaller than windowTokens."
                )
            }
            guard (0...ContextBudgetPolicy.supportedMaximumRecentMessages)
                    .contains(contextBudgetPolicy.keepRecentMessages),
                  (1...ContextBudgetPolicy.supportedMaximumSummaryCharacters)
                    .contains(contextBudgetPolicy.maxSummaryCharacters) else {
                throw AgentError.invalidConfiguration(
                    "Context keepRecentMessages or maxSummaryCharacters exceeds the supported bound."
                )
            }
        }
    }

    private func validate(_ value: Int, name: String, maximum: Int) throws {
        guard (1...maximum).contains(value) else {
            throw AgentError.invalidConfiguration(
                "\(name) must be between 1 and \(maximum)."
            )
        }
    }
}
