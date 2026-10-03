import Foundation
import FoundationModels
import Testing
@testable import AppleLocalAILEAP

@Generable
private struct StructuredAnswer {
  let value: String
}

@Test func pinsTheSmallestTextArtifactWithoutLegacyProviderContracts() {
  let model = AppleLocalAILEAPTextModel.default
  #expect(model == .lfm2_5_230M_q4_0)
  #expect(model.byteCount == 149_080_928)
  #expect(model.sha256.count == 64)
  #expect(model.remoteURL.absoluteString.contains(model.revision))
  #expect(AppleLocalAILEAP.leapSDKVersion == "0.10.13-SNAPSHOT")
}

@Test func pinsTheVersionMatchedAudioBundle() {
  let model = AppleLocalAILEAPAudioModelID.recommended
  #expect(model.artifactFiles.count == 3)
  #expect(model.requiredBytes == 1_063_770_528)
  #expect(model.artifactFiles.allSatisfy { $0.remoteURL.absoluteString.contains(model.revision) })
  #expect(model.artifactFiles.allSatisfy { $0.sha256.count == 64 })
}

@Test func mapsPortableTranscriptEntriesInsideTheFoundationModelsBoundary() throws {
  let transcript = Transcript(entries: [
    .instructions(
      .init(
        segments: [.text(.init(content: "Answer briefly."))],
        toolDefinitions: [])),
    .response(.init(segments: [.text(.init(content: "Earlier answer."))])),
    .prompt(.init(segments: [.text(.init(content: "Current question."))])),
  ])
  let plan = try LEAPTranscriptPlan.make(from: request(transcript: transcript))

  #expect(plan.messages.map(\.role) == [.system, .assistant])
  #expect(plan.messages.last?.content == "Earlier answer.")
  #expect(plan.userMessage == "Current question.")
  #expect(plan.maximumTokens == LEAPTranscriptPlan.defaultMaximumTokens)
}

@Test func rejectsProviderOptionsThatWouldOtherwiseBeSilentlyIgnored() {
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Current question."))]))
  ])

  #expect(throws: AppleLocalAILEAPError.self) {
    _ = try LEAPTranscriptPlan.make(
      from: request(
        transcript: transcript,
        generationOptions: GenerationOptions(temperature: 0.2)))
  }

  #expect(throws: LanguageModelError.self) {
    _ = try LEAPTranscriptPlan.make(
      from: request(
        transcript: transcript,
        contextOptions: ContextOptions(reasoningLevel: .light)))
  }
}

@Test func rejectsToolsAtTheFoundationModelsBoundary() {
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Current question."))]))
  ])
  let tool = Transcript.ToolDefinition(
    name: "lookup",
    description: "Look up a value.",
    parameters: StructuredAnswer.generationSchema)

  #expect(throws: LanguageModelError.self) {
    _ = try LEAPTranscriptPlan.make(
      from: request(transcript: transcript, enabledTools: [tool]))
  }
}

@Test func rejectsUnsupportedAudioInputAtTheAppleAudioBoundary() {
  #expect(throws: AppleLocalAILEAPError.self) {
    _ = try AppleLocalAILEAPAudioInput(samples: [], sampleRate: 16_000)
  }
  #expect(throws: AppleLocalAILEAPError.self) {
    _ = try AppleLocalAILEAPAudioInput(
      samples: [2],
      sampleRate: 16_000)
  }
}

@Test func keepsNativeUsageCountsIndependentFromUTF8ByteCounts() {
  let usage = LEAPGenerationUsage(
    promptTokens: 29,
    cachedPromptTokens: 3,
    completionTokens: 5)

  #expect(usage.promptTokens == 29)
  #expect(usage.cachedPromptTokens == 3)
  #expect(usage.completionTokens == 5)
  #expect(usage.promptTokens + usage.cachedPromptTokens + usage.completionTokens == 37)
}

@Test func awaitedNativePrewarmFailsClosedBeforeModelLoad() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppleLocalAI-LEAP-\(UUID().uuidString)", isDirectory: true)
  let runtime = try AppleLocalAILEAPRuntime(rootURL: root)

  await #expect(throws: AppleLocalAILEAPError.self) {
    try await runtime.prewarmTextModel()
  }
}

private func request(
  transcript: Transcript,
  enabledTools: [Transcript.ToolDefinition] = [],
  schema: GenerationSchema? = nil,
  generationOptions: GenerationOptions = .init(),
  contextOptions: ContextOptions = .init()
) -> LanguageModelExecutorGenerationRequest {
  LanguageModelExecutorGenerationRequest(
    id: UUID(),
    transcript: transcript,
    enabledTools: enabledTools,
    schema: schema,
    generationOptions: generationOptions,
    contextOptions: contextOptions,
    metadata: [:])
}
