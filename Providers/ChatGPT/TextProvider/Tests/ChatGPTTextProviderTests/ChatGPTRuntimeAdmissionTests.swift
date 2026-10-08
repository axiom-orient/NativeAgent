import ChatGPTAccount
import Foundation
import LanguageModelCore
import Testing
@testable import ChatGPTTextProvider

@Test
func runtimeAdmissionAcceptsReadyAccounts() throws {
  let account = try JSONDecoder().decode(
    ChatGPTAccount.self, from: Data(#"{"accountID":"account-1","plan":"plus"}"#.utf8))
  try ChatGPTRuntime.admitRuntimeCreation(for: .ready(account))
}

@Test
func runtimeAdmissionAcceptsExpiredAccounts() throws {
  try ChatGPTRuntime.admitRuntimeCreation(for: .expired)
}

@Test
func runtimeAdmissionRejectsSignedOutAccountsWithStableFailureCode() {
  do {
    try ChatGPTRuntime.admitRuntimeCreation(for: .signedOut)
    Issue.record("Signed-out ChatGPT accounts must not create a runtime.")
  } catch let failure as ModelGenerationFailure {
    #expect(failure.code == .authenticationRequired)
  } catch {
    Issue.record("Unexpected runtime admission error: \(error)")
  }
}

@Test
func runtimeExposesOneCanonicalProviderIdentityAndCapabilitySet() {
  #expect(ChatGPTRuntime.providerID == "chatgpt.subscription")
  #expect(ChatGPTRuntime.capabilities.contains(.textInput))
  #expect(ChatGPTRuntime.capabilities.contains(.textOutput))
  #expect(ChatGPTRuntime.capabilities.contains(.streaming))
  #expect(ChatGPTRuntime.capabilities.contains(.structuredOutput))
  #expect(ChatGPTRuntime.capabilities.contains(.toolCalls))
}
