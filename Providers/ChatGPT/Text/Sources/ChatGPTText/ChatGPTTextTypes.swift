import Foundation

public struct ChatGPTReasoningLevel: Codable, Hashable, Sendable {
  public let effort: String
  public let description: String?

  public init(effort: String, description: String? = nil) {
    self.effort = effort
    self.description = description
  }
}

public struct ChatGPTModelInfo: Codable, Hashable, Sendable {
  public let slug: String
  public let displayName: String?
  public let description: String?
  public let defaultReasoningLevel: String?
  public let supportedReasoningLevels: [ChatGPTReasoningLevel]
  public let visibility: String?
  public let supportedInAPI: Bool?
  public let priority: Int?
  public let contextWindow: Int64?

  public init(
    slug: String,
    displayName: String? = nil,
    description: String? = nil,
    defaultReasoningLevel: String? = nil,
    supportedReasoningLevels: [ChatGPTReasoningLevel] = [],
    visibility: String? = nil,
    supportedInAPI: Bool? = nil,
    priority: Int? = nil,
    contextWindow: Int64? = nil
  ) {
    self.slug = slug
    self.displayName = displayName
    self.description = description
    self.defaultReasoningLevel = defaultReasoningLevel
    self.supportedReasoningLevels = supportedReasoningLevels
    self.visibility = visibility
    self.supportedInAPI = supportedInAPI
    self.priority = priority
    self.contextWindow = contextWindow
  }
}

public struct ChatGPTRateLimitWindow: Codable, Hashable, Sendable {
  public let usedPercent: Int
  public let limitWindowSeconds: Int64?
  public let resetAfterSeconds: Int64?
  public let resetAt: Int64?

  public init(
    usedPercent: Int,
    limitWindowSeconds: Int64? = nil,
    resetAfterSeconds: Int64? = nil,
    resetAt: Int64? = nil
  ) {
    self.usedPercent = usedPercent
    self.limitWindowSeconds = limitWindowSeconds
    self.resetAfterSeconds = resetAfterSeconds
    self.resetAt = resetAt
  }

  public var remainingPercent: Int { 100 - min(100, max(0, usedPercent)) }
}

public struct ChatGPTSpendLimit: Codable, Hashable, Sendable {
  public let limit: String?
  public let used: String?
  public let remaining: String?
  public let remainingPercent: Int?
  public let resetAt: Int64?

  public init(
    limit: String? = nil,
    used: String? = nil,
    remaining: String? = nil,
    remainingPercent: Int? = nil,
    resetAt: Int64? = nil
  ) {
    self.limit = limit
    self.used = used
    self.remaining = remaining
    self.remainingPercent = remainingPercent
    self.resetAt = resetAt
  }
}

public struct ChatGPTAdditionalRateLimit: Codable, Hashable, Sendable {
  public let limitName: String
  public let meteredFeature: String?
  public let primaryWindow: ChatGPTRateLimitWindow?
  public let secondaryWindow: ChatGPTRateLimitWindow?

  public init(
    limitName: String,
    meteredFeature: String? = nil,
    primaryWindow: ChatGPTRateLimitWindow? = nil,
    secondaryWindow: ChatGPTRateLimitWindow? = nil
  ) {
    self.limitName = limitName
    self.meteredFeature = meteredFeature
    self.primaryWindow = primaryWindow
    self.secondaryWindow = secondaryWindow
  }
}

public struct ChatGPTRateLimitSnapshot: Codable, Hashable, Sendable {
  public let planType: String?
  public let allowed: Bool?
  public let limitReached: Bool?
  public let primaryWindow: ChatGPTRateLimitWindow?
  public let secondaryWindow: ChatGPTRateLimitWindow?
  public let rateLimitReachedType: String?
  public let spendControlReached: Bool?
  public let spendLimit: ChatGPTSpendLimit?
  public let additionalRateLimits: [ChatGPTAdditionalRateLimit]
  public let resetCreditsAvailableCount: Int?

  public init(
    planType: String? = nil,
    allowed: Bool? = nil,
    limitReached: Bool? = nil,
    primaryWindow: ChatGPTRateLimitWindow? = nil,
    secondaryWindow: ChatGPTRateLimitWindow? = nil,
    rateLimitReachedType: String? = nil,
    spendControlReached: Bool? = nil,
    spendLimit: ChatGPTSpendLimit? = nil,
    additionalRateLimits: [ChatGPTAdditionalRateLimit] = [],
    resetCreditsAvailableCount: Int? = nil
  ) {
    self.planType = planType
    self.allowed = allowed
    self.limitReached = limitReached
    self.primaryWindow = primaryWindow
    self.secondaryWindow = secondaryWindow
    self.rateLimitReachedType = rateLimitReachedType
    self.spendControlReached = spendControlReached
    self.spendLimit = spendLimit
    self.additionalRateLimits = additionalRateLimits
    self.resetCreditsAvailableCount = resetCreditsAvailableCount
  }
}

public enum ChatGPTModelSelection: Hashable, Sendable {
  case recommended
  case exact(String)
}
