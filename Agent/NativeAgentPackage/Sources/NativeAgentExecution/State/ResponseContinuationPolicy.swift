import Foundation
import NativeAgentDomain

public enum ResponseContinuationMode: String, Codable, Sendable, Equatable {
  case disabled
  case truncatedResponseOnly
}

public struct ResponseContinuationPolicy: Codable, Sendable, Equatable {
  public static let standardMaximumAdditionalTurns = 2
  public static let supportedMaximumAdditionalTurns = RuntimeResourceLimits
    .supportedMaximumIterations

  public let mode: ResponseContinuationMode
  public let maxAdditionalTurns: Int

  public init(
    mode: ResponseContinuationMode = .disabled,
    maxAdditionalTurns: Int = ResponseContinuationPolicy.standardMaximumAdditionalTurns
  ) {
    precondition(
      Self.supports(maxAdditionalTurns: maxAdditionalTurns),
      "maxAdditionalTurns is outside the supported runtime bound"
    )
    self.mode = mode
    self.maxAdditionalTurns = maxAdditionalTurns
  }

  public static let disabled = ResponseContinuationPolicy()

  public static func truncatedResponseOnly(
    maxAdditionalTurns: Int = ResponseContinuationPolicy.standardMaximumAdditionalTurns
  ) -> ResponseContinuationPolicy {
    ResponseContinuationPolicy(
      mode: .truncatedResponseOnly,
      maxAdditionalTurns: maxAdditionalTurns
    )
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case maxAdditionalTurns
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let mode = try container.decode(ResponseContinuationMode.self, forKey: .mode)
    let maxAdditionalTurns = try container.decode(Int.self, forKey: .maxAdditionalTurns)
    guard Self.supports(maxAdditionalTurns: maxAdditionalTurns) else {
      throw DecodingError.dataCorruptedError(
        forKey: .maxAdditionalTurns,
        in: container,
        debugDescription: "maxAdditionalTurns is outside the supported runtime bound"
      )
    }
    self.mode = mode
    self.maxAdditionalTurns = maxAdditionalTurns
  }

  private static func supports(maxAdditionalTurns: Int) -> Bool {
    (0...Self.supportedMaximumAdditionalTurns).contains(maxAdditionalTurns)
  }

  var isEnabled: Bool {
    mode != .disabled && maxAdditionalTurns > 0
  }
}

enum ResponseContinuationMetadata {
  static let policyKey = "responseContinuationPolicy"
  static let syntheticRequestKey = "syntheticAutoContinuation"
  static let syntheticPrompt =
    "Continue from the previous response. Do not repeat completed content. Finish the response."

  static func applying(
    policy: ResponseContinuationPolicy?,
    to metadata: [String: JSONValue]
  ) -> [String: JSONValue] {
    guard let policy else {
      return metadata
    }

    var next = metadata
    next[policyKey] = .object([
      "mode": .string(policy.mode.rawValue),
      "maxAdditionalTurns": .integer(Int64(policy.maxAdditionalTurns)),
    ])
    return next
  }

  static func policy(from metadata: [String: JSONValue]) throws -> ResponseContinuationPolicy {
    guard let rawPolicy = metadata[policyKey] else {
      return .disabled
    }
    do {
      return try rawPolicy.decode(ResponseContinuationPolicy.self)
    } catch {
      throw AgentError.invariantViolation(
        "Invalid response continuation policy metadata: \(error)"
      )
    }
  }

  static var syntheticRequestMetadata: [String: JSONValue] {
    [syntheticRequestKey: .bool(true)]
  }

  static func isSyntheticContinuation(_ message: AgentMessage) -> Bool {
    message.role == .user && message.metadata[syntheticRequestKey]?.boolValue == true
  }
}

struct ResponseContinuationController: Sendable {
  let policy: ResponseContinuationPolicy

  func shouldContinue(
    after turn: ModelTurn,
    snapshot: SessionSnapshot
  ) -> Bool {
    guard policy.isEnabled,
      stopReason(from: turn).map(isContinuationReason(_:)) == true
    else {
      return false
    }
    return syntheticContinuationCount(in: snapshot) < policy.maxAdditionalTurns
  }

  private func syntheticContinuationCount(in snapshot: SessionSnapshot) -> Int {
    var count = 0
    for message in snapshot.messages
    where ResponseContinuationMetadata.isSyntheticContinuation(message) {
      count += 1
      if count >= policy.maxAdditionalTurns { return count }
    }
    return count
  }

  private func stopReason(from turn: ModelTurn) -> ModelStopReason? {
    turn.stopReason ?? stopReason(from: turn.metadata)
  }

  private func stopReason(from metadata: [String: JSONValue]) -> ModelStopReason? {
    if let normalized = ModelStopReasonMetadata.stopReason(from: metadata) {
      return normalized
    }

    let raw = metadata["finishReason"]?.stringValue ?? metadata["stopReason"]?.stringValue
    guard let raw else {
      return nil
    }

    switch raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: " ", with: "_")
    {
    case "max_tokens", "length":
      return .maxTokens
    case "tool_calls", "function_call", "tool_use":
      return .toolUse
    case "stop", "end_turn", "stop_sequence":
      return .stop
    case "refusal":
      return .refusal
    case "content_filter":
      return .contentFilter
    case "safety", "image_safety":
      return .safety
    case "recitation", "image_recitation":
      return .recitation
    default:
      return .other
    }
  }

  private func isContinuationReason(_ stopReason: ModelStopReason) -> Bool {
    switch policy.mode {
    case .disabled:
      return false
    case .truncatedResponseOnly:
      return stopReason == .maxTokens
    }
  }
}
