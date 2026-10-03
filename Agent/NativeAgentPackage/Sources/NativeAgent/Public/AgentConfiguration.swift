import Foundation
import LanguageModelCore
import NativeAgentExecution

/// A host-verified model capacity used to project a durable conversation into
/// the next request. It intentionally contains no provider wire-format detail.
public struct AgentContextCapacity: Sendable, Equatable {
    public let windowTokens: Int
    public let reservedOutputTokens: Int?
    public let triggerRatio: Double
    public let targetRatio: Double
    public let keepRecentMessages: Int
    public let maxSummaryCharacters: Int

    public init(
        windowTokens: Int,
        reservedOutputTokens: Int? = nil,
        triggerRatio: Double = ContextBudgetPolicy.mobileTriggerRatio,
        targetRatio: Double = ContextBudgetPolicy.mobileTargetRatio,
        keepRecentMessages: Int = ContextBudgetPolicy.mobileKeepRecentMessages,
        maxSummaryCharacters: Int = ContextBudgetPolicy.mobileMaxSummaryCharacters
    ) {
        self.windowTokens = windowTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.triggerRatio = triggerRatio
        self.targetRatio = targetRatio
        self.keepRecentMessages = keepRecentMessages
        self.maxSummaryCharacters = maxSummaryCharacters
    }

    package var runtimeValue: ContextBudgetPolicy {
        ContextBudgetPolicy(
            windowTokens: windowTokens,
            reservedOutputTokens: reservedOutputTokens,
            triggerRatio: triggerRatio,
            targetRatio: targetRatio,
            keepRecentMessages: keepRecentMessages,
            maxSummaryCharacters: maxSummaryCharacters,
            preserveSystemMessages: true
        )
    }
}

/// High-level runtime policy exposed to applications.
///
/// NativeAgent always uses transactional persistence, execution claims, and the effect
/// ledger. Applications configure only bounded behavior, not internal store
/// wiring.
public struct AgentConfiguration: Sendable, Equatable {
    public enum ContextPolicy: Sendable, Equatable {
        /// Use the model's declared context window when available, otherwise a
        /// conservative fallback. Durable history is never discarded; only the
        /// next model request is projected.
        case automatic
        /// Use an application-verified model capacity when the provider cannot
        /// expose a trustworthy `ModelDescriptor`.
        case capacity(AgentContextCapacity)
    }

    public let contextPolicy: ContextPolicy
    /// An enforced response schema for tool-free Agent sessions.
    public let outputFormat: ModelOutputFormat

    public init(
        contextPolicy: ContextPolicy = .automatic,
        outputFormat: ModelOutputFormat = .text
    ) {
        self.contextPolicy = contextPolicy
        self.outputFormat = outputFormat
    }

    package var runtimeResourceLimits: RuntimeResourceLimits {
        RuntimeResourceLimits(
            maxToolCallsPerTurn: RuntimeResourceLimits.supportedMaximumToolCallsPerTurn,
            maxTranscriptMessages: RuntimeResourceLimits.supportedMaximumTranscriptMessages
        )
    }

    package var recoveryRuntimeConfiguration: RuntimeConfiguration {
        RuntimeConfiguration(
            contextBudgetPolicy: .mobileDefault,
            safetyPolicy: .durable,
            resourceLimits: runtimeResourceLimits,
            outputFormat: outputFormat
        )
    }

    package func runtimeConfiguration(for descriptor: ModelDescriptor) -> RuntimeConfiguration {
        RuntimeConfiguration(
            contextBudgetPolicy: resolvedContextBudget(for: descriptor),
            safetyPolicy: .durable,
            resourceLimits: runtimeResourceLimits,
            outputFormat: outputFormat
        )
    }

    private func resolvedContextBudget(for descriptor: ModelDescriptor) -> ContextBudgetPolicy {
        switch contextPolicy {
        case .capacity(let capacity):
            return capacity.runtimeValue
        case .automatic:
            guard let windowTokens = descriptor.contextWindowTokens,
                  (1...ContextBudgetPolicy.supportedMaximumWindowTokens).contains(windowTokens) else {
                return .mobileDefault
            }
            let fallback = ContextBudgetPolicy.mobileDefault
            return ContextBudgetPolicy(
                windowTokens: windowTokens,
                triggerRatio: fallback.triggerRatio,
                targetRatio: fallback.targetRatio,
                keepRecentMessages: fallback.keepRecentMessages,
                maxSummaryCharacters: fallback.maxSummaryCharacters,
                preserveSystemMessages: fallback.preserveSystemMessages
            )
        }
    }
}
