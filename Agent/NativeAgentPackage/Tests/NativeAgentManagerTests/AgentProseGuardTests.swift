import Foundation
import NativeAgentManager
import Testing

struct AgentProseGuardTests {
  @Test
  func swiftPortMatchesUpstreamPythonFixtures() throws {
    let url = try #require(Bundle.module.url(forResource: "prose-guard-parity", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    #expect(fixtures.count >= 50)
    for (index, fixture) in fixtures.enumerated() {
      let report = AgentProseGuard.compare(source: fixture.source, candidate: fixture.candidate, anchors: fixture.anchors)
      #expect(report.status.rawValue == fixture.status, "Python parity fixture \(index): \(report.reason ?? "")")
      #expect(report.semanticVerification == "NOT_PERFORMED")
    }
  }

  @Test
  func exactBytesRemainProtectedAcrossUnicodeNormalization() {
    let source = "`caf\u{00E9}`"
    let candidate = "`cafe\u{0301}`"
    #expect(source == candidate) // Swift canonical equivalence must not weaken source preservation.
    let report = AgentProseGuard.compare(source: source, candidate: candidate)
    #expect(report.status == .mechanicalFail)
    #expect(report.sourceSHA256 != report.candidateSHA256)
    #expect(AgentProseGuard.compare(source: "caf\u{00E9}", candidate: "cafe\u{0301}", anchors: ["caf\u{00E9}"]).status == .mechanicalFail)
  }

  @Test
  func rejectsInvalidUTF8AndOversizedInputWithoutExecutingAnything() {
    #expect(AgentProseGuard.compare(source: Data([0xff]), candidate: Data([0xff])).status == .inputError)
    #expect(AgentProseGuard.compare(source: Data([0xef, 0xbb, 0xbf, 65]), candidate: Data([65])).status == .mechanicalFail)
    let large = String(repeating: "x", count: AgentProseGuard.maximumInputBytes + 1)
    #expect(AgentProseGuard.compare(source: large, candidate: large).status == .inputError)
    let code = "```sh\nrm -rf /\n```\n"
    #expect(AgentProseGuard.compare(source: code, candidate: code).status == .mechanicalPassSemanticsUnverified)
  }

  @Test
  func detectsObservedModelWrapperFailureButDoesNotClaimSemanticProof() {
    let source = "Not all requests failed. Keep `retry()` and at most 3 ms."
    let wrapper = "```json\n{\"source\": \"Not all requests failed. Keep `retry()` and at most 3 ms.\"}\n```"
    #expect(AgentProseGuard.compare(source: source, candidate: wrapper).status == .mechanicalFail)
    // This expected lexical PASS documents a blind spot, never acceptance of a changed meaning.
    #expect(AgentProseGuard.compare(source: "Not all requests failed.", candidate: "All requests failed.").status == .mechanicalPassSemanticsUnverified)
    #expect(AgentProseGuard.compare(source: "Not all requests failed.", candidate: "All requests failed.", anchors: ["Not all"]).status == .mechanicalFail)
  }

  @Test
  func nativeSkillCatalogIsLanguageScoped() throws {
    #expect(try AgentNativeWritingSkill.available(for: "ko-KR") == [.fluentKorean, .koreanize])
    #expect(try AgentNativeWritingSkill.available(for: "en-GB") == [.englishPolish])
    #expect(throws: AgentResponseError.invalidRequest) {
      try AgentNativeWritingSkill.fluentKorean.writingRequest(source: "본문")
    }
    let request = try AgentNativeWritingSkill.japanesePolish.writingRequest(source: "文章です。")
    #expect(request.source == "文章です。")
  }

  private struct Fixture: Decodable {
    let source: String
    let candidate: String
    let anchors: [String]
    let status: String
  }
}
