@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import Testing
import NativeAgentDomain

@Suite("Catalog binding shares the final image byte contract")
struct ImageCatalogContractTests {
  private func catalog(template: String = "Draw `SUBJECT` in `STYLE`.", defaultStyle: String = "ink",
    mode: String = "TEXT_ONLY") throws -> ChatGPTImagePromptCatalog {
    let object: [String: Any] = ["schemaVersion": 1, "revision": "test-revision", "categories": [], "prompts": [[
      "id": "TEST-01", "title": "Test", "summary": "Fixture", "mode": mode, "category": "test",
      "source": "test", "template": template, "variables": ["SUBJECT", "STYLE"],
      "requiredVariables": ["SUBJECT"], "defaults": ["STYLE": defaultStyle], "failureCriteria": ["Wrong subject"]]]]
    return try ChatGPTImagePromptCatalog.validated(data: JSONSerialization.data(withJSONObject: object))
  }

  @Test func bindingIsDeterministicAndDoesNotRecursivelyExpandUserContent() throws {
    let catalog = try catalog()
    let result = try catalog.prepare(promptID: "TEST-01", variables: ["SUBJECT": "  `STYLE`  "])
    #expect(result.hasPrefix("Draw `STYLE` in ink."))
    #expect(result.contains("BOUND INPUT VALUES"))
    #expect(try catalog.prepare(promptID: "TEST-01", variables: ["SUBJECT": "`STYLE`"]) == result)
  }

  @Test func defaultsMissingValuesUnknownVariablesAndReferenceCountsAreChecked() throws {
    #expect(throws: AgentError.self) { _ = try catalog(defaultStyle: " ") }
    let text = try catalog()
    for values in [[String: String](), ["SUBJECT": ""], ["SUBJECT": "sun", "WRONG": "x"]] {
      #expect(throws: AgentError.self) { _ = try text.prepare(promptID: "TEST-01", variables: values) }
    }
    #expect(throws: AgentError.self) { _ = try text.prepare(promptID: "TEST-01", variables: ["SUBJECT": "sun"], referenceImageCount: 1) }
    let reference = try catalog(mode: "REFERENCE_IMAGE_REQUIRED")
    for count in [0, 2, -1] {
      #expect(throws: AgentError.self) { _ = try reference.prepare(promptID: "TEST-01", variables: ["SUBJECT": "sun"], referenceImageCount: count) }
    }
    #expect(try reference.prepare(promptID: "TEST-01", variables: ["SUBJECT": "sun"], referenceImageCount: 1).hasPrefix("Draw sun in ink."))
  }

  @Test func preparedUTF8BytesAreCheckedAfterTemplateAndBindings() throws {
    let large = try catalog(template: String(repeating: "한", count: 11_000) + " `SUBJECT`")
    #expect(throws: AgentError.self) { _ = try large.prepare(promptID: "TEST-01", variables: ["SUBJECT": "sun"]) }
  }
}
