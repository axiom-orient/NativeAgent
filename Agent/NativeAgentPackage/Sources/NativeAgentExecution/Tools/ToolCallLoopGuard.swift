import Foundation
import NativeAgentDomain

struct ToolCallFingerprint: Sendable, Equatable {
    let name: String
    let canonicalArguments: String

    init(call: ToolCall) {
        self.name = call.name
        self.canonicalArguments = call.arguments.stableIdentityString()
    }
}

private struct ToolCallOutcome: Sendable, Equatable {
    let isError: Bool
    let stableResult: String

    init(message: AgentMessage) {
        self.isError = message.metadata["isError"]?.boolValue ?? false
        let output = message.metadata["output"]?.stableIdentityString() ?? ""
        self.stableResult = "\(message.content)\n\(output)"
    }
}

private struct ToolCallAttempt: Sendable, Equatable {
    let fingerprint: ToolCallFingerprint
    let outcome: ToolCallOutcome
}

struct ToolCallLoopGuard: Sendable {
    static let threshold = 3
    static let repeatedCallMessage = "This identical tool request has already produced the same result or failure twice in this user turn. Use the observed result to take a different next step."

    private var recent: [ToolCallAttempt]

    init(messages: [AgentMessage]) {
        self.recent = Self.collectRecentAttempts(from: messages)
    }

    func shouldBlock(_ call: ToolCall) -> Bool {
        let fingerprint = ToolCallFingerprint(call: call)
        let tail = recent.suffix(Self.threshold - 1)
        guard tail.count == Self.threshold - 1,
              tail.allSatisfy({ $0.fingerprint == fingerprint }),
              let firstOutcome = tail.first?.outcome else {
            return false
        }

        // Repeated polling is legitimate when the observed result changes.
        // Intervene only after identical input has produced no new information.
        return tail.dropFirst().allSatisfy { $0.outcome == firstOutcome }
    }

    mutating func record(_ call: ToolCall, resultMessage: AgentMessage?) {
        guard let resultMessage, resultMessage.role == .tool else {
            return
        }
        recent.append(
            ToolCallAttempt(
                fingerprint: ToolCallFingerprint(call: call),
                outcome: ToolCallOutcome(message: resultMessage)
            )
        )
        if recent.count > Self.threshold {
            recent.removeFirst()
        }
    }

    private static func collectRecentAttempts(from messages: [AgentMessage]) -> [ToolCallAttempt] {
        guard threshold > 0 else {
            return []
        }

        // A new user message is new evidence and can legitimately request the
        // same action. The guard therefore owns only the active user turn.
        var reversedActiveTurn: [AgentMessage] = []
        for message in messages.reversed() {
            guard message.role != .user else { break }
            reversedActiveTurn.append(message)
        }
        let activeTurn = reversedActiveTurn.reversed()
        var resultByCallID: [String: AgentMessage] = [:]
        for message in activeTurn where message.role == .tool {
            if let callID = message.toolCallID {
                resultByCallID[callID] = message
            }
        }

        var attempts: [ToolCallAttempt] = []
        attempts.reserveCapacity(threshold)
        for message in activeTurn where message.role == .assistant {
            for call in message.toolCalls {
                guard let resultMessage = resultByCallID[call.id] else { continue }
                attempts.append(
                    ToolCallAttempt(
                        fingerprint: ToolCallFingerprint(call: call),
                        outcome: ToolCallOutcome(message: resultMessage)
                    )
                )
            }
        }
        return Array(attempts.suffix(threshold))
    }
}
