import Testing
@testable import AppleLocalAICore

@Test func keepsToolRoundTripWithInitiatingPrompt() {
  let entries: [HistoryEntryKind] = [.prompt, .other, .prompt, .toolCalls, .toolOutput]
  #expect(HistoryWindow.retainedRange(in: entries, limit: 2) == 2..<5)
}

@Test func regularSuffixUsesRequestedLimit() {
  let entries: [HistoryEntryKind] = [.prompt, .other, .prompt, .other]
  #expect(HistoryWindow.retainedRange(in: entries, limit: 2) == 2..<4)
}
