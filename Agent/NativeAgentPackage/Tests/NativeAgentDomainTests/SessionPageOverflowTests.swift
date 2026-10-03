import Testing
import LanguageModelCore
@testable import NativeAgentDomain

@Suite struct SessionPageOverflowTests {
  @Test func externallyConstructedMessagePageDoesNotOverflow() {
    let page = SessionMessagePage(sessionID: "s", offset: .max, totalCount: .max,
                                  messages: [.init(id: "m", role: .user, content: "one")])
    #expect(page.nextOffset == nil)
  }

  @Test func externallyConstructedSearchPageDoesNotOverflow() {
    let page = SessionMessageSearchPage(totalCount: .max, offset: .max,
      matches: [.init(sessionID: "s", sessionTitle: nil, message: .init(id: "m", role: .user, content: "one"))])
    #expect(page.nextOffset == nil)
  }

  @Test func normalPageOffsetIsUnchanged() {
    let page = SessionMessagePage(sessionID: "s", offset: 1, totalCount: 4,
                                  messages: [.init(id: "m", role: .user, content: "one")])
    #expect(page.nextOffset == 2)
  }
}
