import Testing

@testable import LanguageModelCore

@Suite("Bounded UTF-8 failure diagnostics")
struct FailureMessageBoundaryTests {
  @Test func completeMultibyteScalarAtLimitIsPreserved() {
    let limit = ModelGenerationFailure.maximumMessageUTF8Bytes
    for scalar in ["é", "한", "😀"] {
      let prefix = String(repeating: "a", count: limit - scalar.utf8.count) + scalar
      let failure = ModelGenerationFailure(.transportFailure, prefix + "overflow")
      #expect(failure.message == prefix)
      #expect(failure.message.utf8.count == limit)
    }
  }

  @Test func incompleteLastScalarIsOmittedWithoutLosingThePrefix() {
    let limit = ModelGenerationFailure.maximumMessageUTF8Bytes
    for scalar in ["é", "한", "😀"] {
      for count in 1..<scalar.utf8.count {
        let prefix = String(repeating: "a", count: limit - count)
        let failure = ModelGenerationFailure(.transportFailure, prefix + scalar + "suffix")
        #expect(failure.message == prefix)
        #expect(failure.message.utf8.count <= limit)
      }
    }
  }

  @Test func shortDiagnosticRemainsUnchanged() {
    let short = "실패: 😀"
    #expect(ModelGenerationFailure(.transportFailure, short).message == short)
  }
}
