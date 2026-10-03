#if canImport(FoundationModels, _version: 2)
  import FoundationModels
  import FoundationModelsBridge
  import LanguageModelCore
  import Testing

  @Suite("Native SDK 27 bridge compile boundary")
  struct NativeBridgeCompileTests {
    @Test func systemModelHasAnExplicitTextOnlyProjection() throws {
      let model = try FoundationLanguageModel(
        model: SystemLanguageModel.default,
        providerID: "apple.system.bridge", modelID: "system")
      #expect(model.capabilities == .textOnly)
      #expect(model.executorConfiguration == model.executorConfiguration)
      // No live inference: availability, assets and device entitlement are separate checks.
    }

    @Test func sdkFailuresKeepTheStableCoreVocabulary() {
      let failures: [(any Error, String)] = [
        (FoundationModels.LanguageModelError.contextSizeExceeded(
          .init(contextSize: 1, tokenCount: 2, debugDescription: "context")),
          ModelGenerationErrorCode.limitExceeded.rawValue),
        (FoundationModels.LanguageModelError.refusal(
          .init(explanation: "refused", debugDescription: "policy")),
          ModelGenerationErrorCode.policyViolation.rawValue),
        (FoundationModels.LanguageModelError.rateLimited(
          .init(resetDate: nil, debugDescription: "rate")),
          ModelGenerationErrorCode.sourceUnavailable.rawValue),
        (FoundationModels.LanguageModelSession.Error.concurrentRequests, ModelGenerationErrorCode.sourceUnavailable.rawValue),
      ]

      for (error, expectedCode) in failures {
        #expect(FoundationModelFailure(underlyingError: error).modelFailureCode == expectedCode)
      }
    }
  }
#endif
