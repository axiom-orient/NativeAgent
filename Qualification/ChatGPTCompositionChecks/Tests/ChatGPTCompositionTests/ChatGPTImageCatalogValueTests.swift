@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import Testing
import NativeAgentDomain

@Suite struct ChatGPTImageCatalogValueTests {
    private func encodedCatalog(defaultValue: String) throws -> Data {
        let catalog = try ChatGPTImagePromptCatalog.bundled()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
        var prompts = try #require(object["prompts"] as? [[String: Any]])
        let index = try #require(prompts.firstIndex { $0["id"] as? String == "TO-01" })
        var defaults = try #require(prompts[index]["defaults"] as? [String: String])
        defaults["TIME"] = defaultValue
        prompts[index]["defaults"] = defaults
        object["prompts"] = prompts
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test(arguments: ["", " \n\t", String(repeating: "a", count: 4_001)])
    func invalidDefaultCannotBypassValueAdmission(_ value: String) throws {
        let data = try encodedCatalog(defaultValue: value)
        #expect(throws: AgentError.self) { try ChatGPTImagePromptCatalog.validated(data: data) }
        // Codable is public: a decoded snapshot must not bypass the preparation boundary either.
        let decoded = try JSONDecoder().decode(ChatGPTImagePromptCatalog.self, from: data)
        #expect(throws: AgentError.self) {
            try decoded.prepare(promptID: "TO-01", variables: ["PLACE": "Jeju"])
        }
    }

    @Test func upperBoundAndLiteralVariableContentArePreserved() throws {
        let value = String(repeating: "a", count: 4_000)
        let catalog = try ChatGPTImagePromptCatalog.validated(data: encodedCatalog(defaultValue: value))
        let prepared = try catalog.prepare(promptID: "TO-01", variables: ["PLACE": "literal `TIME`"])
        #expect(prepared.contains("literal `TIME`"))
        #expect(prepared.contains(value))
    }

    @Test func allBundledPromptsRemainPreparable() throws {
        let catalog = try ChatGPTImagePromptCatalog.bundled()
        #expect(catalog.prompts.count == 31)
        #expect(catalog.categories.count == 19)
        for prompt in catalog.prompts {
            let values = Dictionary(uniqueKeysWithValues: prompt.requiredVariables.map {
                ($0, $0 == "MICRO_STORIES" ? "walk\nrest\nreturn" : "actual input")
            })
            let prepared = try catalog.prepare(promptID: prompt.id, variables: values,
                referenceImageCount: prompt.mode == .referenceImageRequired ? 1 : 0)
            #expect(!prepared.isEmpty)
        }
    }
}
