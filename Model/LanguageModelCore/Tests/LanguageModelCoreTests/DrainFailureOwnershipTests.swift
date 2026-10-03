import Foundation
import LanguageModelCore
import Testing

@Test func drainFailureRetainsOwnerWithoutPublishingItAsDiagnostics() throws {
  weak var reference: SensitiveOwner?
  var failure: ModelExecutorDrainFailure?
  do {
    let owner = SensitiveOwner()
    reference = owner
    failure = ModelExecutorDrainFailure("Native completion is unproved.", retaining: owner)
  }
  #expect(reference != nil)
  let description = String(describing: try #require(failure))
  let debug = String(reflecting: try #require(failure))
  #expect(description == "Native completion is unproved.")
  #expect(debug == description)
  #expect(try #require(failure).modelFailureDetails.isEmpty)
  failure = nil
  #expect(reference == nil)
}
private final class SensitiveOwner: Sendable, CustomStringConvertible {
  let description = "secret-test-token-must-not-be-published"
}
