@testable import ChatGPTAccount
@testable import ChatGPTText
@testable import ChatGPTImage
@testable import ChatGPTTextProvider
@testable import ChatGPTImageCapability
import Foundation
import Testing
import NativeAgentDomain
import LanguageModelCore

#if canImport(CoreGraphics) && canImport(ImageIO)
@Suite("One approved layer operation, explicit observed outcomes")
struct ImageLayerExecutionTests {
  private func plan(_ api: ChatGPTImageLayers, source: ModelBinaryContent = PNGTestFixture.image()) throws -> ChatGPTImageLayers.Plan {
    try api.prepare(source: source, layers: [.init(id: "subject", subject: "The red subject")])
  }

  @Test func renderSendsTheExactOriginalAndRetainsAlphaAndProvenance() async throws {
    let client = ImageServiceProbe()
    let api = ChatGPTImageLayers(client: client)
    let source = PNGTestFixture.image()
    let plan = try plan(api, source: source)
    let turnID = UUID()
    let outcome = try await api.render(plan: plan, layerID: "subject", source: source, turnID: turnID)
    guard case .candidate(let layer) = outcome else { Issue.record("Expected an admitted candidate, never an implicit success"); return }
    let requests = await client.edits
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.images == [ChatGPTImageContent(source)] && request.size == "2x1")
    #expect(request.background == .transparent && request.quality == .high && request.turnID == turnID)
    #expect(request.prompt.contains("The red subject") && request.prompt.contains("Do not crop"))
    #expect(layer.layerID == "subject" && layer.width == 2 && layer.height == 1)
    #expect(layer.planSHA256 == (try plan.digest()))
    #expect(layer.turnID == turnID && layer.providerRequestID == "fixture-request-id")
    #expect(layer.rgbaSourcePNG == PNGTestFixture.png())
    #expect(layer.providerImageSHA256 == SHA256HexDigest.digest(PNGTestFixture.png()))
    #expect(layer.verification.status == "verified")
    #expect(layer.verification.sourceSHA256 == plan.sourceSHA256)
    #expect(layer.verification.planSHA256 == (try plan.digest()))
    #expect(layer.verification.layerID == "subject" && layer.verification.stackIndex == 0)
    #expect(layer.verification.width == 2 && layer.verification.height == 1)
    #expect(layer.verification.alphaAdmission == .elementHasSubjectAndClearPixels)
    #expect(layer.verification.rgbaSourceSHA256 == layer.providerImageSHA256)
    #expect(layer.verification.chromaProjectionSHA256 == SHA256HexDigest.digest(layer.chromaImage.data))
    #expect(try ChatGPTImageRasterCodec.decode(layer.rgbaSourcePNG).pixels == PNGTestFixture.elementPixels)
    let chroma = try ChatGPTImageRasterCodec.decode(layer.chromaImage.data)
    #expect(chroma.pixels == [255, 0, 0, 255, 0, 177, 64, 255])
    #expect(layer.chromaKey == "#00B140" && layer.chromaImage.filename == "subject.png")
    #expect(await client.generations.isEmpty)
  }

  @Test func sourceDigestAndUnknownLayerFailuresMakeNoRemoteCall() async throws {
    let client = ImageServiceProbe()
    let api = ChatGPTImageLayers(client: client)
    let plan = try plan(api)
    for (id, source) in [("missing", PNGTestFixture.image()), ("subject", PNGTestFixture.image(PNGTestFixture.png()))] {
      do {
        _ = try await api.render(plan: plan, layerID: id, source: source, turnID: UUID())
        Issue.record("A mismatched immutable input must fail before dispatch")
      } catch let failure as EffectFailure {
        #expect(failure.effectFailureCertainty == .definiteFailure)
        #expect(failure.operation == "images.layers.render.preflight")
      }
    }
    #expect(await client.edits.isEmpty)
  }

  @Test func changedCanvasOpaqueElementEmptyLayerAndInvalidPNGRetainRejectedBytes() async throws {
    let cases = [PNGTestFixture.png(width: 1, height: 1, rgba: [255, 0, 0, 255]),
      PNGTestFixture.png(rgba: PNGTestFixture.sourcePixels),
      PNGTestFixture.png(rgba: Array(repeating: 0, count: 8)), Data([1, 2, 3]),
      PNGTestFixture.framed(imageData: [1, 2, 3])]
    for bytes in cases {
      let client = ImageServiceProbe(.returns(PNGTestFixture.response(bytes)))
      let api = ChatGPTImageLayers(client: client)
      let outcome = try await api.render(plan: plan(api), layerID: "subject", source: PNGTestFixture.image(), turnID: UUID())
      guard case .rejected(let rejected) = outcome else { Issue.record("Rejected bytes must not be resized or relabeled as a layer"); continue }
      #expect(rejected.bytes == bytes && !rejected.reason.isEmpty)
      #expect(rejected.providerImageSHA256 == SHA256HexDigest.digest(bytes))
      #expect(rejected.layerID == "subject" && rejected.providerRequestID == "fixture-request-id")
      #expect(await client.edits.count == 1)
    }
  }

  @Test func nonPNGMIMEIsARejectedObservedCandidate() async throws {
    let client = ImageServiceProbe(.returns(PNGTestFixture.response(mime: "image/jpeg")))
    let api = ChatGPTImageLayers(client: client)
    let outcome = try await api.render(plan: plan(api), layerID: "subject", source: PNGTestFixture.image(), turnID: UUID())
    guard case .rejected(let rejected) = outcome else { Issue.record("MIME mismatch must not be accepted"); return }
    #expect(rejected.bytes == PNGTestFixture.png())
    #expect(rejected.reason.contains("non-PNG"))
  }

  @Test func emptyRemoteResultHasUnknownOutcomeAndIsNotRetried() async throws {
    let client = ImageServiceProbe(.returns(PNGTestFixture.response(Data())))
    let api = ChatGPTImageLayers(client: client)
    do {
      _ = try await api.render(plan: plan(api), layerID: "subject", source: PNGTestFixture.image(), turnID: UUID())
      Issue.record("Empty response cannot prove absence of a remote effect")
    } catch let failure as EffectFailure {
      #expect(failure.effectFailureCertainty == .outcomeUnknown)
      #expect(failure.context == ["providerReturned": "true"])
      #expect(failure.operation == "images.layers.render.publication")
    }
    #expect(await client.edits.count == 1)
  }

  @Test func providerFailureClassificationPreservesRetryUncertainty() async throws {
    let cases: [(ChatGPTImageErrorCode, EffectFailureCertainty)] = [
      (.invalidRequest, .definiteFailure), (.authenticationRequired, .definiteFailure),
      (.rateLimited, .definiteFailure),
      (.serviceRejected, .outcomeUnknown), (.malformedResponse, .outcomeUnknown),
      (.limitExceeded, .outcomeUnknown), (.cancelled, .outcomeUnknown), (.transportFailure, .outcomeUnknown)]
    for (code, certainty) in cases {
      let client = ImageServiceProbe(.fails(ChatGPTImageFailure(code)))
      let api = ChatGPTImageLayers(client: client)
      do {
        _ = try await api.render(plan: plan(api), layerID: "subject", source: PNGTestFixture.image(), turnID: UUID())
        Issue.record("Expected the classified provider failure")
      } catch let failure as EffectFailure {
        #expect(failure.effectFailureCertainty == certainty && failure.operation == "images.layers.render")
        #expect(failure.cause.contains(code.rawValue))
      }
      #expect(await client.edits.count == 1)
    }
  }

  @Test func explicitHTTPRejectionIsDefiniteButServerFailureRemainsUnknown() async throws {
    let cases: [(ChatGPTImageFailure, EffectFailureCertainty)] = [
      (ChatGPTImageFailure(.serviceRejected, httpStatusCode: 403), .definiteFailure),
      (ChatGPTImageFailure(.serviceRejected, httpStatusCode: 503), .outcomeUnknown),
      (ChatGPTImageFailure(.limitExceeded, httpStatusCode: 413), .definiteFailure),
      (ChatGPTImageFailure(.limitExceeded), .outcomeUnknown),
    ]
    for (providerFailure, certainty) in cases {
      let client = ImageServiceProbe(.fails(providerFailure))
      let api = ChatGPTImageLayers(client: client)
      do {
        _ = try await api.render(
          plan: plan(api), layerID: "subject", source: PNGTestFixture.image(), turnID: UUID())
        Issue.record("Expected the classified provider failure")
      } catch let failure as EffectFailure {
        #expect(failure.effectFailureCertainty == certainty)
        if providerFailure.httpStatusCode == 403 { #expect(failure.cause.contains("HTTP 403")) }
      }
    }
  }

  @Test func alreadyCancelledTaskDoesNotDispatch() async throws {
    let client = ImageServiceProbe()
    let api = ChatGPTImageLayers(client: client)
    let prepared = try plan(api)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await api.render(plan: prepared, layerID: "subject", source: PNGTestFixture.image(), turnID: UUID())
    }
    do { _ = try await task.value; Issue.record("Pre-dispatch cancellation must fail") }
    catch let failure as EffectFailure {
      #expect(failure.effectFailureCertainty == .definiteFailure)
      #expect(failure.operation == "images.layers.render.preflight")
    }
    #expect(await client.edits.isEmpty)
  }

  @Test func observedResultSurvivesCancellationForKernelPublication() async throws {
    let client = ImageServiceProbe(.cancelsThenReturns(PNGTestFixture.response()))
    let api = ChatGPTImageLayers(client: client)
    let prepared = try plan(api)
    let task = Task {
      try await api.render(plan: prepared, layerID: "subject", source: PNGTestFixture.image(), turnID: UUID())
    }
    let outcome = try await task.value
    guard case .candidate(let layer) = outcome else { Issue.record("Observed bytes must survive task cancellation"); return }
    #expect(layer.rgbaSourcePNG == PNGTestFixture.png())
    #expect(await client.edits.count == 1)
    // This does not claim the Agent SQLite transaction was exercised by this probe.
  }

  @Test func recomposeUsesPlanOrderAndRejectsMissingDuplicateOrForeignCandidates() async throws {
    let source = PNGTestFixture.image()
    let backgroundPNG = PNGTestFixture.png(rgba: [0, 0, 255, 255, 0, 255, 0, 255])
    let backgroundAPI = ChatGPTImageLayers(client: ImageServiceProbe(.returns(PNGTestFixture.response(backgroundPNG))))
    let elementAPI = ChatGPTImageLayers(client: ImageServiceProbe())
    let plan = try backgroundAPI.prepare(source: source, layers: [
      .init(id: "back", subject: "Background", role: .background), .init(id: "front", subject: "Red subject")])
    let background = try await backgroundAPI.render(plan: plan, layerID: "back", source: source, turnID: UUID())
    let foreground = try await elementAPI.render(plan: plan, layerID: "front", source: source, turnID: UUID())
    guard case .candidate(let back) = background, case .candidate(let front) = foreground else {
      Issue.record("Both structural fixture candidates are required"); return
    }
    #expect(back.verification.alphaAdmission == .backgroundHasSubject)
    #expect(front.verification.alphaAdmission == .elementHasSubjectAndClearPixels)
    let composite = try elementAPI.recompose(plan: plan, layers: [front, back])
    #expect(try ChatGPTImageRasterCodec.decode(composite.data).pixels == [255, 0, 0, 255, 0, 255, 0, 255])
    let persisted = try [front, back].map { layer in
      try ChatGPTImageLayers.RecompositionSource(layerID: layer.layerID, planSHA256: layer.planSHA256,
        png: layer.rgbaSourcePNG, contentSHA256: layer.providerImageSHA256)
    }
    let restored = try elementAPI.recomposeVerified(plan: plan, sources: persisted)
    #expect(try ChatGPTImageRasterCodec.decode(restored.image.data).pixels == [255, 0, 0, 255, 0, 255, 0, 255])
    #expect(restored.verification.status == "verified")
    #expect(restored.verification.planSHA256 == (try plan.digest()))
    #expect(restored.verification.planSourceSHA256 == plan.sourceSHA256)
    #expect(restored.verification.layerIDsBackToFront == ["back", "front"])
    #expect(restored.verification.rgbaSourceSHA256sBackToFront == [back.providerImageSHA256, front.providerImageSHA256])
    #expect(restored.verification.outputSHA256 == SHA256HexDigest.digest(restored.image.data))
    #expect(throws: AgentError.self) {
      _ = try ChatGPTImageLayers.RecompositionSource(layerID: front.layerID, planSHA256: front.planSHA256,
        png: front.rgbaSourcePNG, contentSHA256: String(repeating: "0", count: 64))
    }
    #expect(throws: AgentError.self) { _ = try elementAPI.recompose(plan: plan, layers: [front]) }
    #expect(throws: AgentError.self) { _ = try elementAPI.recompose(plan: plan, layers: [front, front]) }
    let otherPlan = try elementAPI.prepare(source: source, layers: [
      .init(id: "back", subject: "Changed meaning", role: .background), .init(id: "front", subject: "Red subject")])
    #expect(throws: AgentError.self) { _ = try elementAPI.recompose(plan: otherPlan, layers: [front, back]) }
  }
}
#endif
