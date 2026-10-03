import FoundationModels
import Testing
@testable import AppleLocalAI

@Test func rejectsRequiredToolsWhenToolListIsEmpty() {
  #expect(throws: AppleLocalAIError.requiredToolCallingWithoutTools) {
    _ = try AppleLocalAIProfile(toolCallingMode: .required)
  }
}

@Test func rejectsNonPositiveHistoryLimit() {
  #expect(throws: AppleLocalAIError.invalidHistoryLimit) {
    _ = try AppleLocalAIProfile(historyPolicy: .recentEntries(0))
  }
}

@Test func rejectsNonPositiveMaximumResponseTokens() {
  for value in [0, -1] {
    #expect(throws: AppleLocalAIError.invalidMaximumResponseTokens) {
      _ = try AppleLocalAIProfile(maximumResponseTokens: value)
    }
  }
}

@Test func rejectsInvalidTemperature() {
  for value in [-0.01, 1.01, .nan, .infinity] {
    #expect(throws: AppleLocalAIError.invalidTemperature) {
      _ = try AppleLocalAIProfile(temperature: value)
    }
  }
}

@Test func mapsNativeModelCapabilitiesWithoutInventingCapabilities() {
  let capabilities = AppleLocalAIModelCapabilities(
    LanguageModelCapabilities([.vision, .toolCalling])
  )

  #expect(capabilities.supportsVision)
  #expect(capabilities.supportsToolCalling)
  #expect(!capabilities.supportsGuidedGeneration)
  #expect(!capabilities.supportsReasoning)
}
