import ChatGPTAccount
import CoreFoundation
import Foundation

/// Pure account-response decoding. It cannot refresh credentials or publish account state.
enum ChatGPTTextPayload {
  static let maximumResponseBytes = 1 * 1_024 * 1_024

  static func selectRecommendedModel(
    from models: [ChatGPTModelInfo]
  ) throws -> ChatGPTModelInfo {
    let candidates = models.filter { $0.visibility == "list" }.sorted { lhs, rhs in
      switch (lhs.priority, rhs.priority) {
      case (let left?, let right?) where left != right:
        return left < right
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return lhs.slug < rhs.slug
      }
    }
    guard let selected = candidates.first else { throw ChatGPTFailure(.modelUnavailable) }
    return selected
  }

  static func parseRateLimits(_ data: Data) throws -> ChatGPTRateLimitSnapshot {
    let root = try object(data)
    let rateLimit = try objectValue(root["rate_limit"])
    let reachedType: String?
    if let value = root["rate_limit_reached_type"] as? String {
      reachedType = value
    } else if let value = root["rate_limit_reached_type"] as? [String: Any] {
      reachedType = value["type"] as? String
    } else {
      reachedType = nil
    }
    let spendLimit: ChatGPTSpendLimit?
    let spendControlReached: Bool?
    if let spendControl = try objectValue(root["spend_control"]) {
      spendControlReached = spendControl["reached"] as? Bool
      if let individual = try objectValue(spendControl["individual_limit"]) {
        spendLimit = ChatGPTSpendLimit(
          limit: stringValue(individual["limit"]),
          used: stringValue(individual["used"]),
          remaining: stringValue(individual["remaining"]),
          remainingPercent: integerValue(individual["remaining_percent"]),
          resetAt: integerValue(individual["reset_at"]).map(Int64.init))
      } else {
        spendLimit = nil
      }
    } else {
      spendControlReached = nil
      spendLimit = nil
    }
    let additional: [ChatGPTAdditionalRateLimit]
    if let values = try arrayValue(root["additional_rate_limits"]) {
      additional = try values.map { value in
        guard let name = value["limit_name"] as? String, !name.isEmpty else {
          throw ChatGPTFailure(.malformedResponse)
        }
        let nested = try objectValue(value["rate_limit"])
        return ChatGPTAdditionalRateLimit(
          limitName: name,
          meteredFeature: value["metered_feature"] as? String,
          primaryWindow: try parseWindow(nested?["primary_window"]),
          secondaryWindow: try parseWindow(nested?["secondary_window"]))
      }
    } else {
      additional = []
    }
    let resetCreditsAvailableCount =
      (root["rate_limit_reset_credits"] as? [String: Any]).flatMap {
        integerValue($0["available_count"])
      }
    return ChatGPTRateLimitSnapshot(
      planType: root["plan_type"] as? String,
      allowed: rateLimit?["allowed"] as? Bool,
      limitReached: rateLimit?["limit_reached"] as? Bool,
      primaryWindow: try parseWindow(rateLimit?["primary_window"]),
      secondaryWindow: try parseWindow(rateLimit?["secondary_window"]),
      rateLimitReachedType: reachedType,
      spendControlReached: spendControlReached,
      spendLimit: spendLimit,
      additionalRateLimits: additional,
      resetCreditsAvailableCount: resetCreditsAvailableCount)
  }

  private static func parseWindow(_ value: Any?) throws -> ChatGPTRateLimitWindow? {
    guard let object = try objectValue(value) else { return nil }
    guard let usedPercent = integerValue(object["used_percent"])
    else { throw ChatGPTFailure(.malformedResponse) }
    return ChatGPTRateLimitWindow(
      usedPercent: usedPercent,
      limitWindowSeconds: integerValue(object["limit_window_seconds"]).map(Int64.init),
      resetAfterSeconds: integerValue(object["reset_after_seconds"]).map(Int64.init),
      resetAt: integerValue(object["reset_at"]).map(Int64.init))
  }

  private static func objectValue(_ value: Any?) throws -> [String: Any]? {
    guard let value, !(value is NSNull) else { return nil }
    guard let object = value as? [String: Any] else {
      throw ChatGPTFailure(.malformedResponse)
    }
    return object
  }

  private static func arrayValue(_ value: Any?) throws -> [[String: Any]]? {
    guard let value, !(value is NSNull) else { return nil }
    guard let array = value as? [[String: Any]] else {
      throw ChatGPTFailure(.malformedResponse)
    }
    return array
  }

  private static func integerValue(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else {
      return nil
    }
    let integer = number.int64Value
    guard integer >= 0, integer <= Int64(Int.max), number.doubleValue == Double(integer) else {
      return nil
    }
    return Int(integer)
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  static func object(_ data: Data) throws -> [String: Any] {
    guard !data.isEmpty, data.count <= maximumResponseBytes,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw ChatGPTFailure(.malformedResponse) }
    return object
  }
}

extension ChatGPTModelInfo {
  init?(_ value: [String: Any]) {
    guard let slug = value["slug"] as? String,
      (try? chatGPTValidateModel(slug)) != nil
    else { return nil }
    let reasoningLevels =
      (value["supported_reasoning_levels"] as? [[String: Any]])?
      .compactMap { value -> ChatGPTReasoningLevel? in
        guard let effort = value["effort"] as? String, !effort.isEmpty else { return nil }
        return ChatGPTReasoningLevel(
          effort: effort, description: value["description"] as? String)
      } ?? []
    let priority = chatGPTInteger(value, "priority").flatMap(Int.init(exactly:))
    self.init(
      slug: slug,
      displayName: value["display_name"] as? String,
      description: value["description"] as? String,
      defaultReasoningLevel: value["default_reasoning_level"] as? String,
      supportedReasoningLevels: reasoningLevels,
      visibility: value["visibility"] as? String,
      supportedInAPI: value["supported_in_api"] as? Bool,
      priority: priority,
      contextWindow: chatGPTInteger(value, "context_window"))
  }
}
