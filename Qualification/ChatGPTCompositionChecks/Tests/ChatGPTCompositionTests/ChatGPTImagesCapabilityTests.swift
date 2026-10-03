@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import NativeAgentDomain
import LanguageModelCore
import NativeAgentSkills
import Testing


@Test
func imagesToolPackGeneratesVerifiedArtifact() async throws {
  let stub = StubImageClient()
  let capability = ChatGPTImagesCapability(client: stub)
  let executor = try #require(capability.executors().first { $0.definition.name == "images.generate" })
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

  let result = try await executor.execute(
    call: ToolCall(
      id: "call-image",
      name: "images.generate",
      arguments: [
        "prompt": "a translucent jellyfish icon",
        "background": "auto",
        "quality": "high",
        "size": "auto",
        "output_filename": "jellyfish",
      ]
    ),
    context: ToolExecutionContext(sessionID: "session", sessionDirectoryURL: root, sandboxRootURL: root)
  )

  let request = try #require(await stub.lastGenerationRequest)
  #expect(request.background == .auto)
  #expect(request.quality == .high)
  #expect(result.isError == false)
  #expect(result.artifacts.count == 1)
  #expect(result.artifacts[0].preferredFilename == "jellyfish.png")
  #expect(result.metadata["providerID"]?.stringValue == ChatGPTRuntime.providerID)
  #expect(result.metadata["model"]?.stringValue == ChatGPTImageClient.model)
  #expect(result.output.objectValue?["verification"]?.objectValue?["status"]?.stringValue == "verified")
}

@Test
func imageEffectIntentRequiresSelectedSkill() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = makeSkillLibrary(root: root)
  let stub = StubImageClient()
  let router = ChatGPTImageSkills.makeIntentRouter(client: stub)
  let runtime = SkillRuntime(
    library: library,
    scriptRunner: NoopScriptRunner(),
    intentService: router
  )
  let stickerIntent = ChatGPTImageSkillIntents.effect("sticker-cutout")

  await #expect(throws: AgentError.self) {
    _ = try await runtime.runIntent(
      intent: stickerIntent,
      parametersJSON: "{\"prompt\":\"a smiling tofu mascot\"}",
      callID: "blocked",
      context: toolContext(root: root)
    )
  }
  #expect(await stub.generationCount == 0)

  _ = try await ChatGPTImageSkills.installDefaultSkills(into: library, selected: true)
  let result = try await runtime.runIntent(
    intent: stickerIntent,
    parametersJSON: "{\"prompt\":\"a smiling tofu mascot\"}",
    callID: "allowed",
    context: toolContext(root: root)
  )

  let request = try #require(await stub.lastGenerationRequest)
  #expect(request.background == .transparent)
  #expect(request.prompt.contains("sticker-style cutout"))
  #expect(result.metadata["intentName"]?.stringValue == stickerIntent)
}

@Test
func installDefaultImageSkillsPersistsIntentAuthority() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = makeSkillLibrary(root: root)

  let installed = try await ChatGPTImageSkills.installDefaultSkills(into: library, selected: true)
  let snapshot = try await library.snapshot()

  #expect(installed.count == ChatGPTImageSkills.effectCatalog.count + 1)
  let sticker = try #require(snapshot.skills.first { $0.name == "image-sticker-cutout" })
  #expect(sticker.selected)
  #expect(sticker.defaultSelected == true)
  #expect(sticker.capabilityRequirements.hostIntents == [ChatGPTImageSkillIntents.effect("sticker-cutout")])
  let transform = try #require(snapshot.skills.first { $0.name == "image-transform" })
  #expect(transform.capabilityRequirements.hostIntents == [ChatGPTImageSkillIntents.transform])
}

@Test
func imageEditReadsExactCurrentSessionArtifact() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let sessionID = "session"
  let relativePath = "sessions/\(sessionID)/artifacts/source.png"
  let url = root.appendingPathComponent(relativePath)
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let source = fixturePNG()
  try source.write(to: url)

  let stub = StubImageClient()
  let capability = ChatGPTImagesCapability(client: stub)
  let executor = try #require(capability.executors().first { $0.definition.name == "images.edit" })
  let result = try await executor.execute(
    call: ToolCall(
      id: "edit",
      name: "images.edit",
      arguments: [
        "images": [[
          "mime_type": "image/png",
          "artifact_relative_path": .string(relativePath),
          "sha256": .string(SHA256HexDigest.digest(source)),
        ]],
        "prompt": "make the subject red",
      ]
    ),
    context: ToolExecutionContext(sessionID: sessionID, sessionDirectoryURL: root, sandboxRootURL: root)
  )

  let edit = try #require(await stub.lastEditRequest)
  #expect(edit.images.count == 1)
  #expect(edit.images[0].data == source)
  #expect(result.isError == false)
}

@Test
func deterministicProviderRejectionIsClassifiedWithoutRetryPermission() async throws {
  let client = FailingImageClient(error: ChatGPTImageFailure(.rateLimited))
  let capability = ChatGPTImagesCapability(client: client)
  let executor = try #require(capability.executors().first { $0.definition.name == "images.generate" })

  do {
    _ = try await executor.execute(
      call: ToolCall(id: "rate", name: "images.generate", arguments: ["prompt": "test"]),
      context: toolContext(root: FileManager.default.temporaryDirectory)
    )
    Issue.record("rate-limited image generation unexpectedly succeeded")
  } catch let failure as EffectFailure {
    #expect(failure.effectFailureCertainty == .definiteFailure)
  }
}

@Test
func imageEditRejectsDirectorySymlinkToAnotherSessionBeforeDispatch() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let artifacts = root.appendingPathComponent("sessions/session/artifacts")
  let foreign = root.appendingPathComponent("sessions/other/artifacts")
  try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
  let source = fixturePNG()
  try source.write(to: foreign.appendingPathComponent("source.png"))
  try FileManager.default.createSymbolicLink(
    at: artifacts.appendingPathComponent("alias"), withDestinationURL: foreign)
  let stub = StubImageClient()
  let executor = try #require(ChatGPTImagesCapability(client: stub).executors().first {
    $0.definition.name == "images.edit"
  })
  await #expect(throws: EffectFailure.self) {
    _ = try await executor.execute(
      call: ToolCall(id: "cross-session", name: "images.edit", arguments: [
        "images": [[
          "mime_type": "image/png",
          "artifact_relative_path": "sessions/session/artifacts/alias/source.png",
          "sha256": .string(SHA256HexDigest.digest(source)),
        ]],
        "prompt": "make it red",
      ]), context: toolContext(root: root))
  }
  #expect(await stub.lastEditRequest == nil)
}

@Test
func imageEditRejectsExcessInputsBeforeDispatch() async throws {
  let stub = StubImageClient()
  let payload: JSONValue = [
    "mime_type": "image/png", "base64": .string(fixturePNG().base64EncodedString()),
  ]
  let executor = try #require(ChatGPTImagesCapability(client: stub).executors().first {
    $0.definition.name == "images.edit"
  })
  await #expect(throws: EffectFailure.self) {
    _ = try await executor.execute(
      call: ToolCall(id: "too-many", name: "images.edit", arguments: [
        "images": .array(Array(repeating: payload, count: 6)), "prompt": "make it red",
      ]), context: toolContext(root: FileManager.default.temporaryDirectory))
  }
  #expect(await stub.lastEditRequest == nil)
}

@Test
func imageArtifactReaderRejectsChangedBytesLinksAndOversizeFiles() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("sessions/session/artifacts/nested")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let source = fixturePNG()
  let digest = SHA256HexDigest.digest(source)
  let file = directory.appendingPathComponent("source.png")
  try source.write(to: file)
  let path = "sessions/session/artifacts/nested/source.png"
  #expect(try ChatGPTSessionArtifactInputResolver.read(
    relativePath: path, expectedSHA256: digest, context: toolContext(root: root)) == source)
  #expect(throws: AgentError.self) {
    try ChatGPTSessionArtifactInputResolver.read(
      relativePath: path, expectedSHA256: SHA256HexDigest.digest(Data()), context: toolContext(root: root))
  }
  try FileManager.default.createSymbolicLink(
    at: directory.appendingPathComponent("link.png"), withDestinationURL: file)
  #expect(throws: AgentError.self) {
    try ChatGPTSessionArtifactInputResolver.read(
      relativePath: "sessions/session/artifacts/nested/link.png", expectedSHA256: digest,
      context: toolContext(root: root))
  }
  let handle = try FileHandle(forWritingTo: file)
  try handle.truncate(atOffset: UInt64(ChatGPTImageClient.maximumInputImageBytes + 1))
  try handle.close()
  #expect(throws: AgentError.self) {
    try ChatGPTSessionArtifactInputResolver.read(
      relativePath: path, expectedSHA256: digest, context: toolContext(root: root))
  }
}

actor StubImageClient: ChatGPTImageServing {
  private(set) var lastGenerationRequest: ChatGPTImageGenerationRequest?
  private(set) var lastEditRequest: ChatGPTImageEditRequest?
  private(set) var generationCount = 0

  func generate(_ request: ChatGPTImageGenerationRequest) async throws -> ChatGPTImageResult {
    generationCount += 1
    lastGenerationRequest = request
    return ChatGPTImageResult(
      image: ChatGPTImageContent(mimeType: "image/png", data: fixturePNG(), filename: "result.png"),
      createdAt: Date(),
      background: request.background,
      quality: request.quality,
      size: request.size,
      imageGenerationRequestID: "fixture-request"
    )
  }

  func edit(_ request: ChatGPTImageEditRequest) async throws -> ChatGPTImageResult {
    lastEditRequest = request
    return ChatGPTImageResult(
      image: ChatGPTImageContent(mimeType: "image/png", data: fixturePNG(), filename: "edited.png"),
      createdAt: Date(),
      background: request.background,
      quality: request.quality,
      size: request.size
    )
  }
}

private struct FailingImageClient: ChatGPTImageServing {
  let error: ChatGPTImageFailure

  func generate(_ request: ChatGPTImageGenerationRequest) async throws -> ChatGPTImageResult {
    throw error
  }

  func edit(_ request: ChatGPTImageEditRequest) async throws -> ChatGPTImageResult {
    throw error
  }
}

private struct NoopScriptRunner: SkillScriptRunner {
  func run(
    skill: ManagedSkill,
    scriptURL: URL,
    readAccessURL: URL?,
    inputJSON: String,
    secret: String?,
    context: ToolExecutionContext
  ) async throws -> SkillScriptResponse {
    SkillScriptResponse(result: "noop")
  }
}

private func makeSkillLibrary(root: URL) -> SkillLibrary {
  SkillLibrary(
    workspace: .init(
      supportRootURL: root.appendingPathComponent("Support", isDirectory: true),
      userSkillsRootURL: root.appendingPathComponent("Documents/Skills", isDirectory: true)
    )
  )
}

private func toolContext(root: URL) -> ToolExecutionContext {
  ToolExecutionContext(sessionID: "session", sessionDirectoryURL: root, sandboxRootURL: root)
}

private func fixturePNG() -> Data {
  Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  )!
}
