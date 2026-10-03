import ChatGPTAccount
@testable import ChatGPTText
import Foundation
import Testing


/// Pure response-contract tests; these do not contact or authenticate with ChatGPT.
@Suite struct ChatGPTAccountPayloadTests {
  @Test func visiblePriorityAndSlugDetermineRecommendation() throws {
    let models = [
      ChatGPTModelInfo(slug: "hidden", visibility: "hide", priority: 0),
      ChatGPTModelInfo(slug: "z", visibility: "list", priority: 1),
      ChatGPTModelInfo(slug: "a", visibility: "list", priority: 1),
      ChatGPTModelInfo(slug: "no-priority", visibility: "list"),
    ]
    #expect(try ChatGPTTextPayload.selectRecommendedModel(from: models).slug == "a")
  }

  @Test func noVisibleModelFailsClosed() {
    #expect(throws: ChatGPTFailure(.modelUnavailable)) {
      try ChatGPTTextPayload.selectRecommendedModel(
        from: [ChatGPTModelInfo(slug: "hidden", visibility: "hide")])
    }
  }

  @Test func responseMustBeBoundedNonemptyObject() {
    let invalid = [
      Data(), Data("[]".utf8), Data("not-json".utf8),
      Data(repeating: 32, count: ChatGPTTextPayload.maximumResponseBytes + 1),
    ]
    for data in invalid {
      #expect(throws: ChatGPTFailure(.malformedResponse)) {
        try ChatGPTTextPayload.object(data)
      }
    }
  }

  @Test func booleanAndFractionalQuotaAreNotIntegers() {
    for number in ["true", "1.5", "-1"] {
      let data = Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(number)}}}".utf8)
      #expect(throws: ChatGPTFailure(.malformedResponse)) {
        try ChatGPTTextPayload.parseRateLimits(data)
      }
    }
  }

  @Test func optionalNullSectionsAndQuotaValuesArePreserved() throws {
    let data = Data(
      #"{"plan_type":"fixture","rate_limit":{"allowed":true,"primary_window":{"used_percent":35,"reset_at":100}},"spend_control":null,"additional_rate_limits":null}"#
        .utf8)
    let value = try ChatGPTTextPayload.parseRateLimits(data)
    #expect(value.planType == "fixture")
    #expect(value.allowed == true)
    #expect(value.primaryWindow?.remainingPercent == 65)
    #expect(value.primaryWindow?.resetAt == 100)
    #expect(value.spendLimit == nil)
    #expect(value.additionalRateLimits.isEmpty)
  }

  @Test func malformedAdditionalLimitCannotDisappearSilently() {
    let data = Data(#"{"additional_rate_limits":[{"limit_name":""}]}"#.utf8)
    #expect(throws: ChatGPTFailure(.malformedResponse)) {
      try ChatGPTTextPayload.parseRateLimits(data)
    }
  }

  @Test func modelDecoderPreservesValidatedIdentityAndNumericFields() throws {
    let value = try #require(
      ChatGPTModelInfo([
        "slug": "fixture-model", "visibility": "list", "priority": 2,
        "context_window": 4096,
        "supported_reasoning_levels": [["effort": "low", "description": "fixture"]],
      ]))
    #expect(value.slug == "fixture-model")
    #expect(value.priority == 2)
    #expect(value.contextWindow == 4096)
    #expect(value.supportedReasoningLevels.first?.effort == "low")
    #expect(ChatGPTModelInfo(["slug": "invalid/model"]) == nil)
  }
}
