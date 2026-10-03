@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import ChatGPTAgent
import Foundation
import LanguageModelCore
import Testing


@Suite("ChatGPT runtime admission")
struct ChatGPTRuntimeAdmissionTests {
  @Test func readyAndExpiredAccountsMayCreateARuntime() throws {
    let account = try JSONDecoder().decode(
      ChatGPTAccount.self,
      from: Data(#"{"accountID":"account"}"#.utf8)
    )
    try ChatGPTRuntime.admitRuntimeCreation(for: .ready(account))
    try ChatGPTRuntime.admitRuntimeCreation(for: .expired)
  }

  @Test func signedOutAccountIsRejected() throws {
    do {
      try ChatGPTRuntime.admitRuntimeCreation(for: .signedOut)
      Issue.record("Unauthenticated account unexpectedly passed runtime admission.")
    } catch let failure as ModelGenerationFailure {
      #expect(failure.code == .authenticationRequired)
    }
  }

  @Test func providerIdentityIsCanonical() {
    #expect(ChatGPTRuntime.providerID == "chatgpt.subscription")
  }

  @Test func providerAdvertisesCanonicalToolCallsWithoutOwningExecution() {
    #expect(ChatGPTRuntime.capabilities.contains(.toolCalls))
    #expect(ChatGPTRuntime.capabilities.contains(.structuredOutput))
    #expect(ChatGPTRuntime.capabilities.contains(.streaming))
  }
}
