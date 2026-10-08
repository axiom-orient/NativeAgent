import Foundation
import NativeAgentDomain

public struct ApproximateTokenEstimator: Sendable {
    public init() {}

    public func estimate(messages: [AgentMessage], tools: [ToolDefinition]) throws -> Int {
        var messageTokens = 0
        for message in messages {
            let metadataTokens = try estimate(json: .object(message.metadata))
            var toolCallTokens = 0
            for call in message.toolCalls {
                let argumentTokens = try estimate(json: call.arguments)
                let nameTokens = try estimate(text: call.name)
                let callTokens = try checkedAdd(
                    try checkedAdd(argumentTokens, nameTokens),
                    4
                )
                toolCallTokens = try checkedAdd(toolCallTokens, max(4, callTokens))
            }
            let contentTokens = try estimate(text: message.content)
            let messageCost = try checkedAdd(
                try checkedAdd(
                    try checkedAdd(contentTokens, metadataTokens),
                    toolCallTokens
                ),
                8
            )
            messageTokens = try checkedAdd(messageTokens, max(8, messageCost))
        }

        var toolTokens = 0
        for tool in tools {
            let schemaTokens = try estimate(json: tool.inputSchema)
            let toolCost = try checkedAdd(
                try checkedAdd(
                    try checkedAdd(try estimate(text: tool.name), try estimate(text: tool.description)),
                    schemaTokens
                ),
                12
            )
            toolTokens = try checkedAdd(toolTokens, max(12, toolCost))
        }

        return try checkedAdd(messageTokens, toolTokens)
    }

    public func estimate(json: JSONValue) throws -> Int {
        // JSON arguments and metadata can contain non-ASCII text. Two UTF-8
        // bytes per token deliberately leaves headroom for tokenizers that
        // split CJK, emoji, escape-heavy strings, or source-like values more
        // finely than plain English prose. The provider remains authoritative.
        try roundedUpDivision(try json.canonicalUTF8ByteCount(), by: 2)
    }

    private func estimate(text: String) throws -> Int {
        var asciiBytes = 0
        var nonASCIIBytes = 0
        for byte in text.utf8 {
            if byte < 0x80 {
                asciiBytes = try checkedAdd(asciiBytes, 1)
            } else {
                nonASCIIBytes = try checkedAdd(nonASCIIBytes, 1)
            }
        }

        // English and most source text commonly tokenise in short multi-byte
        // groups, while non-ASCII text needs a smaller bytes-per-token ratio.
        // This avoids the old Character.count / 4 undercount for CJK without
        // forcing ordinary prompts to compact at a two-bytes-per-token rate.
        return try checkedAdd(
            try roundedUpDivision(asciiBytes, by: 3),
            try roundedUpDivision(nonASCIIBytes, by: 2)
        )
    }

    private func roundedUpDivision(_ value: Int, by divisor: Int) throws -> Int {
        guard value > 0 else { return 0 }
        let (adjusted, overflow) = value.addingReportingOverflow(divisor - 1)
        guard !overflow else {
            throw AgentError.budgetExceeded("Approximate token count exceeded the supported integer range.")
        }
        return adjusted / divisor
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw AgentError.budgetExceeded("Approximate token count exceeded the supported integer range.")
        }
        return value
    }
}

public struct CompactionResult: Sendable, Equatable {
    public let messages: [AgentMessage]
    public let checkpoint: SessionContextCheckpoint?
    public let approxTokensBefore: Int
    public let approxTokensAfter: Int
    public let compactedMessageCount: Int

    public init(
        messages: [AgentMessage],
        checkpoint: SessionContextCheckpoint? = nil,
        approxTokensBefore: Int,
        approxTokensAfter: Int,
        compactedMessageCount: Int
    ) {
        self.messages = messages
        self.checkpoint = checkpoint
        self.approxTokensBefore = approxTokensBefore
        self.approxTokensAfter = approxTokensAfter
        self.compactedMessageCount = compactedMessageCount
    }
}

/// Exact model-input projection derived from one durable session revision.
/// The request footprint comes from ModelCore's canonical validator; this type
/// never reimplements byte accounting.
package struct ContextProjection: Sendable, Equatable {
    package let sourceRevision: Int64
    package let sourceMessageRange: Range<Int>
    package let summarizedSourceRange: Range<Int>?
    package let retainedSourceRange: Range<Int>
    package let request: ModelRequest
    package let footprint: ModelInputFootprint

    package init(
        snapshot: SessionSnapshot,
        request: ModelRequest,
        footprint: ModelInputFootprint,
        checkpointApplied: Bool
    ) throws {
        let count = snapshot.messages.count
        let checkpoint = checkpointApplied ? snapshot.contextCheckpoint : nil
        let summarizedSourceRange: Range<Int>?
        let retainedSourceRange: Range<Int>
        if let checkpoint {
            guard checkpoint.preservedSystemMessageCount >= 0,
                  checkpoint.coveredMessageCount >= checkpoint.preservedSystemMessageCount,
                  checkpoint.coveredMessageCount <= count else {
                throw AgentError.invariantViolation(
                    "Context projection checkpoint is outside the durable transcript."
                )
            }
            summarizedSourceRange =
                checkpoint.preservedSystemMessageCount..<checkpoint.coveredMessageCount
            retainedSourceRange = checkpoint.coveredMessageCount..<count
        } else {
            summarizedSourceRange = nil
            retainedSourceRange = 0..<count
        }
        guard footprint.messageCount == request.messages.count else {
            throw AgentError.invariantViolation(
                "Context projection footprint does not match the projected request."
            )
        }
        self.sourceRevision = snapshot.revision
        self.sourceMessageRange = 0..<count
        self.summarizedSourceRange = summarizedSourceRange
        self.retainedSourceRange = retainedSourceRange
        self.request = request
        self.footprint = footprint
    }
}

public struct ContextWindowCompactor: Sendable {
    public static let minimumMeaningfulSummaryCharacters = 64
    private static let projectedMetadataKeys: Set<String> = [
        "artifactReference", "attemptID", "callID", "effectState", "error", "operationID", "status"
    ]
    private let estimator: ApproximateTokenEstimator

    public init(estimator: ApproximateTokenEstimator = ApproximateTokenEstimator()) {
        self.estimator = estimator
    }

    public func compactIfNeeded(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        policy: ContextBudgetPolicy,
        now: Date = Date()
    ) throws -> CompactionResult? {
        try compactIfNeeded(
            snapshot: SessionSnapshot(
                sessionID: "context-projection",
                messages: messages
            ),
            tools: tools,
            policy: policy,
            now: now
        )
    }

    public func projectedMessages(
        for snapshot: SessionSnapshot
    ) throws -> [AgentMessage] {
        try snapshot.validateState()
        guard let checkpoint = snapshot.contextCheckpoint else {
            return snapshot.messages
        }
        return Array(
            snapshot.messages.prefix(checkpoint.preservedSystemMessageCount)
        ) + [checkpoint.summaryMessage] + Array(
            snapshot.messages.dropFirst(checkpoint.coveredMessageCount)
        )
    }

    /// Returns a compaction for `snapshot`, or `nil` when none is applied.
    ///
    /// `nil` means no useful compaction can be produced. Public calls retain
    /// the token-triggered behavior; AgentLoop may use the package-only exact
    /// request-pressure path when ModelCore rejects the projected request.
    public func compactIfNeeded(
        snapshot: SessionSnapshot,
        tools: [ToolDefinition],
        policy: ContextBudgetPolicy,
        now: Date = Date(),
        minimumRetainedMessageIndex: Int? = nil
    ) throws -> CompactionResult? {
        try compact(
            snapshot: snapshot,
            tools: tools,
            policy: policy,
            now: now,
            force: false,
            maximumProjectedMessages: nil,
            minimumRetainedMessageIndex: minimumRetainedMessageIndex
        )
    }

    /// Package-only hard-contract recovery. It preserves the newest message and
    /// returns only a candidate; AgentLoop validates that candidate against the
    /// exact ModelRequest contract before persisting the checkpoint.
    package func compactForRequestContract(
        snapshot: SessionSnapshot,
        tools: [ToolDefinition],
        policy: ContextBudgetPolicy,
        now: Date,
        maximumProjectedMessages: Int,
        minimumRetainedMessageIndex: Int? = nil
    ) throws -> CompactionResult? {
        guard maximumProjectedMessages > 0 else {
            throw AgentError.invalidConfiguration(
                "Context projection message limit must be positive."
            )
        }
        return try compact(
            snapshot: snapshot,
            tools: tools,
            policy: policy,
            now: now,
            force: true,
            maximumProjectedMessages: maximumProjectedMessages,
            minimumRetainedMessageIndex: minimumRetainedMessageIndex
        )
    }

    private func compact(
        snapshot: SessionSnapshot,
        tools: [ToolDefinition],
        policy: ContextBudgetPolicy,
        now: Date,
        force: Bool,
        maximumProjectedMessages: Int?,
        minimumRetainedMessageIndex: Int?
    ) throws -> CompactionResult? {
        try snapshot.validateState()
        guard (1...ContextBudgetPolicy.supportedMaximumWindowTokens).contains(policy.windowTokens),
              policy.reservedOutputTokens >= 0,
              policy.reservedOutputTokens < policy.windowTokens,
              policy.targetRatio.isFinite,
              policy.triggerRatio.isFinite,
              policy.targetRatio > 0,
              policy.triggerRatio > policy.targetRatio,
              policy.triggerRatio <= 1,
              (0...ContextBudgetPolicy.supportedMaximumRecentMessages)
                .contains(policy.keepRecentMessages),
              (Self.minimumMeaningfulSummaryCharacters...ContextBudgetPolicy.supportedMaximumSummaryCharacters)
                .contains(policy.maxSummaryCharacters) else {
            throw AgentError.invalidConfiguration(
                "Context compaction policy is outside its supported bounds."
            )
        }
        let leadingSystemCount: Int
        if policy.preserveSystemMessages {
            leadingSystemCount =
                snapshot.messages.firstIndex(where: { $0.role != .system })
                ?? snapshot.messages.count
        } else {
            leadingSystemCount = 0
        }

        let reusableCheckpoint =
            snapshot.contextCheckpoint?.preservedSystemMessageCount == leadingSystemCount
                ? snapshot.contextCheckpoint
                : nil
        let coveredMessageCount =
            reusableCheckpoint?.coveredMessageCount ?? leadingSystemCount
        let prefix = Array(snapshot.messages.prefix(leadingSystemCount))
        let uncovered = Array(snapshot.messages.dropFirst(coveredMessageCount))
        let body = (reusableCheckpoint.map { [$0.summaryMessage] } ?? []) + uncovered
        let currentProjection = prefix + body
        let before = try estimator.estimate(messages: currentProjection, tools: tools)
        guard force || before > policy.triggerTokens else {
            return nil
        }

        // System messages are instructions, not ordinary transcript. Once a
        // non-leading system message appears, compaction must not advance past
        // it because representing it inside an assistant summary changes its
        // authority. This may leave a request above the approximate target; in
        // that case the provider remains authoritative instead of silently
        // weakening instructions.
        let previouslySummarizedCount = reusableCheckpoint == nil ? 0 : 1
        let firstProtectedSystemOffset = uncovered.firstIndex(where: { $0.role == .system })
            ?? uncovered.count
        var maximumCompactableCount = previouslySummarizedCount + firstProtectedSystemOffset
        if let minimumRetainedMessageIndex {
            guard (0..<snapshot.messages.count).contains(minimumRetainedMessageIndex),
                  minimumRetainedMessageIndex >= coveredMessageCount else {
                throw AgentError.invalidConfiguration(
                    "Active turn source is already covered by a context checkpoint."
                )
            }
            maximumCompactableCount = min(
                maximumCompactableCount,
                previouslySummarizedCount + minimumRetainedMessageIndex - coveredMessageCount
            )
        }
        if maximumProjectedMessages != nil {
            // Exact-contract recovery must never make the newest durable message
            // disappear into a lossy summary.
            maximumCompactableCount = min(
                maximumCompactableCount,
                previouslySummarizedCount + max(0, uncovered.count - 1)
            )
        }

        var minimumNewCoverage = reusableCheckpoint == nil ? 2 : 1
        if let maximumProjectedMessages {
            // projected count = leading system + summary + uncovered tail
            let requiredCoveredMessageCount = max(
                coveredMessageCount,
                leadingSystemCount + 1 + snapshot.messages.count - maximumProjectedMessages
            )
            minimumNewCoverage = max(
                minimumNewCoverage,
                requiredCoveredMessageCount - coveredMessageCount
            )
        }
        guard maximumCompactableCount >= previouslySummarizedCount + minimumNewCoverage else {
            return nil
        }

        let preferredTailCount = min(max(0, policy.keepRecentMessages), uncovered.count)
        let preferredNewCoverage = max(minimumNewCoverage, uncovered.count - preferredTailCount)
        let firstCompactableCount = min(
            maximumCompactableCount,
            previouslySummarizedCount + preferredNewCoverage
        )
        let startCompactableCount = max(
            previouslySummarizedCount + minimumNewCoverage,
            firstCompactableCount
        )
        let prefixTokens = try estimator.estimate(messages: prefix, tools: [])
        let toolTokens = try estimator.estimate(messages: [], tools: tools)
        var bestCandidate: CompactionResult?

        for compactableCount in startCompactableCount...maximumCompactableCount {
            let compactable = Array(body.prefix(compactableCount))
            let newlyCoveredCount = compactableCount - previouslySummarizedCount
            let newCoveredMessageCount = coveredMessageCount + newlyCoveredCount
            guard newCoveredMessageCount <= snapshot.messages.count else {
                continue
            }

            let tailArray = Array(snapshot.messages.dropFirst(newCoveredMessageCount))
            let tailTokens = try estimator.estimate(messages: tailArray, tools: [])
            let fixedTokens = try checkedTokenSum(prefixTokens, tailTokens, toolTokens)
            let summaryMessage = try makeProjectionMessage(
                compactable,
                maximumCharacters: policy.maxSummaryCharacters,
                targetTokens: policy.targetTokens,
                fixedTokens: fixedTokens,
                compactedMessageCount: newCoveredMessageCount - leadingSystemCount,
                now: now
            )
            guard preservesCriticalEvidence(summaryMessage, from: compactable) else {
                // Do not compact a tool record if the bounded projection would
                // erase its operation identity, arguments, or safe receipt
                // metadata. Leaving the original transcript lets the provider
                // reject the request explicitly instead of acting on invented
                // or incomplete tool history.
                continue
            }
            let after = try checkedTokenSum(
                try estimator.estimate(messages: [summaryMessage], tools: []),
                fixedTokens
            )

            guard after < before else { continue }
            let result = CompactionResult(
                messages: prefix + [summaryMessage] + tailArray,
                checkpoint: SessionContextCheckpoint(
                    preservedSystemMessageCount: leadingSystemCount,
                    coveredMessageCount: newCoveredMessageCount,
                    summaryMessage: summaryMessage
                ),
                approxTokensBefore: before,
                approxTokensAfter: after,
                compactedMessageCount: compactable.count
            )
            if after <= policy.targetTokens {
                return result
            }
            // Keep the candidate that reduces the request the most without
            // replacing transcript evidence with an information-free marker.
            if let currentBest = bestCandidate {
                if after < currentBest.approxTokensAfter {
                    bestCandidate = result
                }
            } else {
                bestCandidate = result
            }
        }

        return bestCandidate
    }

    private func makeProjectionMessage(
        _ messages: [AgentMessage],
        maximumCharacters: Int,
        targetTokens: Int,
        fixedTokens: Int,
        compactedMessageCount: Int,
        now: Date
    ) throws -> AgentMessage {
        func message(maximumCharacters: Int) -> AgentMessage {
            AgentMessage(
                role: .assistant,
                content: "Bounded extract of earlier context (not a complete summary):\n" + boundedTranscriptExtract(
                    messages,
                    maximumCharacters: maximumCharacters
                ),
                createdAt: now,
                metadata: [
                    "syntheticSummary": .bool(true),
                    "contextProjection": .string("extractive.v1"),
                    "lossyProjection": .bool(true),
                    "compactedMessageCount": .integer(Int64(compactedMessageCount))
                ]
            )
        }

        let maximum = max(1, maximumCharacters)
        var candidate = message(maximumCharacters: maximum)
        var candidateTokens = try checkedTokenSum(
            try estimator.estimate(messages: [candidate], tools: []),
            fixedTokens
        )
        guard candidateTokens > targetTokens, maximum > 1 else {
            return candidate
        }

        // Find the largest extract that fits the approximate target. Unlike the
        // old fallback this never replaces prior context with a generic sentence.
        var lower = 1
        var upper = maximum
        var best: AgentMessage?
        while lower <= upper {
            let midpoint = lower + (upper - lower) / 2
            let proposed = message(maximumCharacters: midpoint)
            let tokens = try checkedTokenSum(
                try estimator.estimate(messages: [proposed], tools: []),
                fixedTokens
            )
            if tokens <= targetTokens {
                best = proposed
                lower = midpoint + 1
            } else {
                upper = midpoint - 1
            }
        }
        if let best {
            return best
        }

        // Even the smallest useful extract cannot satisfy the approximate
        // target. Keep a bounded identifying excerpt for every compacted
        // message and let the caller's exact ModelRequest contract make the
        // authoritative capacity decision. The public minimum prevents this
        // branch from becoming an information-free placeholder.
        let (scaledMessageCount, scaleOverflow) = messages.count.multipliedReportingOverflow(by: 24)
        let requestedEvidenceCharacters: Int
        if scaleOverflow {
            requestedEvidenceCharacters = Int.max
        } else {
            let (value, addOverflow) = scaledMessageCount.addingReportingOverflow(32)
            requestedEvidenceCharacters = addOverflow ? Int.max : value
        }
        let minimumEvidenceCharacters = min(
            maximum,
            max(Self.minimumMeaningfulSummaryCharacters, requestedEvidenceCharacters)
        )
        candidate = message(maximumCharacters: minimumEvidenceCharacters)
        candidateTokens = try checkedTokenSum(
            try estimator.estimate(messages: [candidate], tools: []),
            fixedTokens
        )
        _ = candidateTokens
        return candidate
    }

    private func checkedTokenSum(_ values: Int...) throws -> Int {
        var total = 0
        for value in values {
            guard value >= 0 else {
                throw AgentError.invariantViolation("Approximate token estimates must not be negative.")
            }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else {
                throw AgentError.budgetExceeded("Approximate token count exceeded the supported integer range.")
            }
            total = next
        }
        return total
    }

    private func boundedTranscriptExtract(
        _ messages: [AgentMessage],
        maximumCharacters: Int
    ) -> String {
        guard maximumCharacters > 0, messages.isEmpty == false else { return "" }

        let rendered = messages.map(renderMessage)
        let full = rendered.joined(separator: "\n")
        guard full.count > maximumCharacters else { return full }
        guard maximumCharacters > 1 else { return "…" }

        // A tiny equal slice for every message eventually degenerates into a
        // prefix-only string once separator overhead exceeds the budget. Sample
        // evenly across the compacted range instead, then share the character
        // budget across those samples. This preserves evidence from both old and
        // newer portions of a long range without pretending to be a semantic
        // summary.
        let minimumUsefulExcerpt = 12
        let sampleLimit = max(
            1,
            min(rendered.count, (maximumCharacters + 1) / (minimumUsefulExcerpt + 1))
        )
        let selectedIndices = evenlySpacedIndices(count: rendered.count, limit: sampleLimit)
        let selected = selectedIndices.map { rendered[$0] }
        let separatorCost = max(0, selected.count - 1)
        let usable = max(1, maximumCharacters - separatorCost)
        let baseBudget = max(1, usable / selected.count)
        let remainder = max(0, usable - baseBudget * selected.count)

        let excerpts = selected.enumerated().map { offset, text in
            boundedExcerpt(
                text,
                maximumCharacters: baseBudget + (offset < remainder ? 1 : 0)
            )
        }
        return excerpts.joined(separator: "\n")
    }

    private func evenlySpacedIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        guard limit < count else { return Array(0..<count) }
        guard limit > 1 else { return [0] }

        return (0..<limit).map { position in
            position * (count - 1) / (limit - 1)
        }
    }

    private func renderMessage(_ message: AgentMessage) -> String {
        let role: String
        switch message.role {
        case .assistant where message.toolCalls.isEmpty == false:
            let calls = message.toolCalls.map { call in
                let arguments = canonicalOrStableIdentity(call.arguments)
                return "\(call.name)#\(call.id)(\(arguments))"
            }.joined(separator: ",")
            role = "assistant{tools=\(calls)}"
        case .tool:
            let name = message.toolName.map { "[\($0)]" } ?? ""
            let callID = message.toolCallID.map { "#\($0)" } ?? ""
            role = "tool\(name)\(callID)"
        default:
            role = message.role.rawValue
        }
        let metadata = message.metadata.keys
            .filter { Self.projectedMetadataKeys.contains($0) }
            .sorted()
            .map { key in
                let value = message.metadata[key].map { canonicalOrStableIdentity($0) } ?? "<missing>"
                return "\(key)=\(value)"
            }
            .joined(separator: ",")
        let metadataSuffix = metadata.isEmpty ? "" : " metadata{\(metadata)}"
        return "\(role)\(metadataSuffix): \(message.content)"
    }

    private func preservesCriticalEvidence(
        _ projection: AgentMessage,
        from messages: [AgentMessage]
    ) -> Bool {
        let evidence = messages.flatMap { message -> [String] in
            var values = message.toolCalls.flatMap { call in
                [call.id, call.name, canonicalOrStableIdentity(call.arguments)]
            }
            if let toolName = message.toolName { values.append(toolName) }
            if let toolCallID = message.toolCallID { values.append(toolCallID) }
            values.append(contentsOf: message.metadata
                .filter { Self.projectedMetadataKeys.contains($0.key) }
                .map { canonicalOrStableIdentity($0.value) })
            return values.filter { !$0.isEmpty }
        }
        return evidence.allSatisfy(projection.content.contains)
    }

    private func canonicalOrStableIdentity(_ value: JSONValue) -> String {
        do {
            return try value.canonicalString()
        } catch {
            return value.stableIdentityString()
        }
    }

    private func boundedExcerpt(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        guard maximumCharacters > 1 else { return "…" }
        guard maximumCharacters > 3 else {
            return String(text.prefix(maximumCharacters - 1)) + "…"
        }

        let contentBudget = maximumCharacters - 1
        // The beginning carries the role and the identifying part of the
        // message. Preserve that prefix before spending the remaining budget
        // on a tail excerpt; splitting the budget evenly can cut identifiers
        // such as "old-assistant" in half.
        let headCount = min(24, contentBudget)
        let tailCount = contentBudget - headCount
        return String(text.prefix(headCount)) + "…" + String(text.suffix(tailCount))
    }

}
