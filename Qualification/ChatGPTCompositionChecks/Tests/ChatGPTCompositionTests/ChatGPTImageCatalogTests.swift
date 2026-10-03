@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import ImageIO
import NativeAgentDomain
import LanguageModelCore
import Testing

@Suite struct ChatGPTImageCatalogTests {
@Test func catalogIncludesAllPromptsAndNativeDecodablePreviews() throws {
  let catalog = try ChatGPTImagePromptCatalog.bundled()
  #expect(catalog.prompts.filter { $0.id.hasPrefix("IR-") }.count == 13)
  #expect(catalog.prompts.filter { $0.id.hasPrefix("TO-") }.count == 6)
  #expect(catalog.categories.count == 19)
  #expect(!catalog.categories.contains { $0.promptIDs.contains("IR-10") })
  for category in catalog.categories {
    for thumbnail in [false, true] {
      let url = try catalog.previewURL(categoryID: category.id, thumbnail: thumbnail)
      let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
      let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      #expect(max(image.width, image.height) <= (thumbnail ? 480 : 960))
    }
  }
  for prompt in catalog.prompts {
    let variables = Dictionary(uniqueKeysWithValues: prompt.requiredVariables.map {
      ($0, $0 == "MICRO_STORIES" ? "walk\nrest\nreturn" : "user-supplied subject")
    })
    let text = try catalog.prepare(promptID: prompt.id, variables: variables,
      referenceImageCount: prompt.mode == .referenceImageRequired ? 1 : 0)
    #expect(!text.isEmpty)
    for variable in prompt.variables { #expect(!text.contains("`\(variable)`")) }
  }
}

@Test func catalogRejectsMissingAndConflictingInputs() throws {
  let catalog = try ChatGPTImagePromptCatalog.bundled()
  #expect(throws: AgentError.self) { try catalog.prepare(promptID: "IR-01") }
  #expect(throws: AgentError.self) { try catalog.prepare(promptID: "TO-01") }
  #expect(throws: AgentError.self) { try catalog.prepare(promptID: "TO-01", variables: ["PLACE": "Paris"], referenceImageCount: 1) }
  #expect(throws: AgentError.self) { try catalog.prepare(promptID: "TO-01", variables: ["PLACE": " "]) }
  #expect(throws: AgentError.self) { try catalog.prepare(promptID: "IR-01", variables: ["UNDECLARED": "value"], referenceImageCount: 1) }
  #expect(throws: AgentError.self) { try catalog.prepare(promptID: "IR-05", variables: ["STICKER_COUNT": "3"], referenceImageCount: 1) }
  #expect(throws: AgentError.self) { try catalog.prepare(promptID: "IR-13", variables: ["MICRO_STORIES": "one"], referenceImageCount: 1) }
  let variables = ["PLACE": "literal `TIME`", "TIME": "night"]
  #expect(try catalog.prepare(promptID: "TO-01", variables: variables) == catalog.prepare(promptID: "TO-01", variables: variables))
  #expect(try catalog.prepare(promptID: "TO-01", variables: variables).contains("literal `TIME`"))
}

@Test func catalogRejectsInvalidVersionAndMappings() throws {
  let catalog = try ChatGPTImagePromptCatalog.bundled()
  let encoded = try JSONEncoder().encode(catalog)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object["schemaVersion"] = 99
  #expect(throws: AgentError.self) { try ChatGPTImagePromptCatalog.validated(data: JSONSerialization.data(withJSONObject: object)) }
  object["schemaVersion"] = 1
  var categories = try #require(object["categories"] as? [[String: Any]])
  categories[0]["promptIDs"] = ["missing"]
  object["categories"] = categories
  #expect(throws: AgentError.self) { try ChatGPTImagePromptCatalog.validated(data: JSONSerialization.data(withJSONObject: object)) }
}

@Test func catalogToolsRouteRealInputsAndRetainProvenance() async throws {
  let client = StubImageClient()
  let catalog = try ChatGPTImagePromptCatalog.bundled()
  let executors = ChatGPTImagesCapability(client: client).executors()
  let run = try #require(executors.first { $0.definition.name == "images.catalog.run" })
  #expect(run.definition.approvalPolicy == .requireApproval)
  #expect(run.definition.effect == .mutation)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let context = ToolExecutionContext(sessionID: "catalog", sessionDirectoryURL: root, sandboxRootURL: root)
  var parameters: JSONValue = ["prompt_id": "TO-01", "catalog_revision": .string(catalog.revision), "variables": ["PLACE": "Jeju"]]
  let generated = try await run.execute(call: ToolCall(id: "gen", name: run.definition.name, arguments: parameters), context: context)
  #expect(await client.lastGenerationRequest?.prompt.contains("Jeju") == true)
  #expect(generated.artifacts.first?.metadata["promptID"] == "TO-01")
  #expect(generated.output["semanticVerification"] == "not_run")
  let png = try #require(generated.artifacts.first?.data)
  parameters = ["prompt_id": "IR-01", "catalog_revision": .string(catalog.revision), "images": [["mime_type": "image/png", "base64": .string(png.base64EncodedString())]]]
  _ = try await run.execute(call: ToolCall(id: "edit", name: run.definition.name, arguments: parameters), context: context)
  #expect(await client.lastEditRequest?.images.first?.data == png)
  #expect(await client.lastEditRequest?.prompt.contains("woodblock") == true)
  let read = try #require(executors.first { $0.definition.name == "images.catalog.read" })
  #expect(read.definition.effect == .readOnly)
  let preview = try await read.execute(call: ToolCall(id: "read", name: read.definition.name, arguments: ["prompt_id": "IR-01"]), context: context)
  #expect(preview.artifacts.first?.mimeType == "image/webp")
  #expect(preview.artifacts.first?.metadata["notGenerationResult"] == true)
}

@Test func catalogPreflightDoesNotDispatchMissingReferenceOrStaleRevision() async throws {
  let client = StubImageClient()
  let catalog = try ChatGPTImagePromptCatalog.bundled()
  let run = try #require(ChatGPTImagesCapability(client: client).executors().first { $0.definition.name == "images.catalog.run" })
  let root = FileManager.default.temporaryDirectory
  let context = ToolExecutionContext(sessionID: "catalog", sessionDirectoryURL: root, sandboxRootURL: root)
  for parameters: JSONValue in [
    ["prompt_id": "IR-01", "catalog_revision": .string(catalog.revision)],
    ["prompt_id": "TO-01", "catalog_revision": "stale", "variables": ["PLACE": "Jeju"]],
    ["prompt_id": "TO-01", "catalog_revision": .string(catalog.revision)],
  ] {
    await #expect(throws: EffectFailure.self) {
      _ = try await run.execute(call: ToolCall(id: "invalid", name: run.definition.name, arguments: parameters), context: context)
    }
  }
  #expect(await client.generationCount == 0)
  #expect(await client.lastEditRequest == nil)
}

@Test func catalogRejectsConflictingBackgroundBeforeDispatch() async throws {
  let client = StubImageClient()
  let catalog = try ChatGPTImagePromptCatalog.bundled()
  let run = try #require(ChatGPTImagesCapability(client: client).executors().first { $0.definition.name == "images.catalog.run" })
  let root = FileManager.default.temporaryDirectory
  let context = ToolExecutionContext(sessionID: "catalog", sessionDirectoryURL: root, sandboxRootURL: root)
  let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
  let arguments: JSONValue = [
    "prompt_id": "IR-05", "catalog_revision": .string(catalog.revision),
    "variables": ["BACKGROUND": "white"], "background": "transparent",
    "images": [["mime_type": "image/png", "base64": .string(bytes.base64EncodedString())]],
  ]
  await #expect(throws: EffectFailure.self) {
    _ = try await run.execute(call: ToolCall(id: "conflict", name: run.definition.name, arguments: arguments), context: context)
  }
  #expect(await client.lastEditRequest == nil)
}

}
