@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import Testing
import NativeAgentDomain
import LanguageModelCore

@Suite("Image capability wiring and external effect boundaries")
struct ImageToolContractTests {
  @Test func existingToolsRemainAndOnlyLayerRenderRequiresAMutation() throws {
    let definitions = ChatGPTImagesToolPack(client: ImageServiceProbe()).executors().map(\.definition)
    #expect(Set(definitions.map(\.name)) == ["images.generate", "images.edit", "images.catalog.list",
      "images.catalog.read", "images.catalog.run", "images.layers.plan", "images.layers.render"])
    #expect(definitions.count == 7)
    let plan = try #require(definitions.first { $0.name == "images.layers.plan" })
    let render = try #require(definitions.first { $0.name == "images.layers.render" })
    #expect(plan.effect == .readOnly && plan.approvalPolicy == .automatic)
    #expect(render.effect == .mutation && render.approvalPolicy == .requireApproval)
    #expect(render.inputSchema["additionalProperties"] == .bool(false))
  }

  @Test func invalidDirectArgumentsNeverReachTheProvider() async throws {
    let client = ImageServiceProbe()
    let tool = try #require(ChatGPTImagesToolPack(client: client).executors().first { $0.definition.name == "images.generate" })
    do {
      _ = try await tool.execute(call: ToolCall(id: "bad", name: "images.generate",
        arguments: .object(["prompt": .string("subject"), "quality": .bool(false)])), context: PNGTestFixture.context())
      Issue.record("Invalid direct arguments cannot become defaults")
    } catch let failure as EffectFailure {
      #expect(failure.effectFailureCertainty == .definiteFailure)
      #expect(failure.operation == "images.generate.preflight")
    }
    #expect(await client.generations.isEmpty)
  }

  @Test func promptPrefixIsAdmittedAfterCombination() async throws {
    let client = ImageServiceProbe()
    let args = try ChatGPTGenerateImageToolArguments(.object(["prompt": .string("subject")]))
    do {
      _ = try await ChatGPTImagesToolPack.generateResult(client: client, arguments: args,
        callID: "prefix", toolName: "images.generate", promptPrefix: String(repeating: "a", count: 32 * 1024))
      Issue.record("The final request, not each fragment alone, must fit the prompt limit")
    } catch let failure as EffectFailure {
      #expect(failure.effectFailureCertainty == .definiteFailure)
    }
    #expect(await client.generations.isEmpty)
  }

  @Test func directPublicationFailureAfterProviderReturnIsUnknownNotAbsent() async throws {
    let client = ImageServiceProbe(.returns(PNGTestFixture.response(Data([1, 2, 3]))))
    let args = try ChatGPTGenerateImageToolArguments(.object(["prompt": .string("subject")]))
    do {
      _ = try await ChatGPTImagesToolPack.generateResult(client: client, arguments: args, callID: "bad-png", toolName: "images.generate")
      Issue.record("Bad result bytes cannot prove that the remote request never ran")
    } catch let failure as EffectFailure {
      #expect(failure.effectFailureCertainty == .outcomeUnknown)
      #expect(failure.operation == "images.generate.publication")
      #expect(failure.context == ["providerReturned": "true"])
    }
    #expect(await client.generations.count == 1)
  }

  #if canImport(CoreGraphics) && canImport(ImageIO)
  @Test func directResultDoesNotClaimSemanticVerification() throws {
    let result = try ChatGPTImageToolResultBuilder.makeResult(callID: "one", toolName: "images.generate",
      requestPrompt: "subject", requestedBackground: .transparent, requestedSize: "2x1",
      result: PNGTestFixture.response(), preferredFilename: nil)
    #expect(result.artifacts.count == 1 && result.artifacts[0].data == PNGTestFixture.png())
    #expect(result.metadata["semanticVerification"] == .string("not_run"))
    #expect(result.output["verificationScope"] == .string("png_structure_dimensions_alpha_only"))
    #expect(result.output["verification"]?["status"] == .string("verified"))
  }

  @Test func planAndRenderUseSeparateArtifactsAndOneVisibleImage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let artifactDirectory = root.appendingPathComponent("sessions/layer-tests/artifacts", isDirectory: true)
    try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record(error, "Temporary layer tool fixture cleanup failed") }
    }
    let context = PNGTestFixture.context(root: root)
    let client = ImageServiceProbe()
    let tools = ChatGPTImagesToolPack(client: client).executors()
    let planTool = try #require(tools.first { $0.definition.name == "images.layers.plan" })
    let source = PNGTestFixture.inline(PNGTestFixture.image().data)
    let proposed = try await planTool.execute(call: ToolCall(id: "plan-call", name: "images.layers.plan", arguments: .object([
      "image": source, "layers": .array([.object(["id": .string("red"), "subject": .string("red subject"), "role": .string("element")])]),
    ])), context: context)
    #expect(await client.edits.isEmpty)
    #expect(proposed.artifacts.count == 1 && proposed.artifacts[0].mimeType == "application/json")
    #expect(try FileManager.default.contentsOfDirectory(atPath: artifactDirectory.path).isEmpty)
    // The test simulates persistence of returned bytes; it does not claim a kernel transaction.
    let planBytes = try #require(proposed.artifacts.first).data
    let path = "sessions/layer-tests/artifacts/image-layer-plan.json"
    try planBytes.write(to: root.appendingPathComponent(path))
    let renderTool = try #require(tools.first { $0.definition.name == "images.layers.render" })
    let rendered = try await renderTool.execute(call: ToolCall(id: "render-call", name: "images.layers.render", arguments: .object([
      "plan_artifact_relative_path": .string(path), "plan_sha256": .string(SHA256HexDigest.digest(planBytes)),
      "image": source, "layer_id": .string("red"),
    ])), context: context)
    #expect(!rendered.isError && rendered.artifacts.count == 2)
    #expect(rendered.artifacts.map(\.preferredFilename) == ["red.png", "red.rgba-source"])
    #expect(rendered.artifacts.map(\.mimeType) == ["image/png", "application/octet-stream"])
    #expect(rendered.artifacts[1].data == PNGTestFixture.png())
    #expect(rendered.artifacts[1].metadata["display"] == .bool(false))
    #expect(rendered.metadata["status"] == .string("candidate_review_required"))
    #expect(rendered.metadata["contractVerification"] == .string("verified"))
    #expect(proposed.metadata["contractVerification"] == .string("verified"))
    #expect(rendered.metadata["semanticVerification"] == .string("not_run"))
    #expect(rendered.metadata["recompositionVerification"] == .string("not_run"))
    #expect(rendered.metadata["sourceSHA256"] == .string(SHA256HexDigest.digest(PNGTestFixture.image().data)))
    #expect(try FileManager.default.contentsOfDirectory(atPath: artifactDirectory.path) == ["image-layer-plan.json"])
    #expect(await client.edits.count == 1)
  }
  #endif
}
