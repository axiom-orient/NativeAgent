import Foundation
import ChatGPTAccount
import ChatGPTImage
import NativeAgentDomain
import LanguageModelCore

/// One provider-facing entry point for a proposed semantic plan and independent layer candidates.
/// The calling Agent analyzes the actual image. This type does not pretend to be a segmentation model.
/// Approval, durable effect identity, storage and retries remain owned by the Agent kernel/host.
public struct ChatGPTImageLayers: Sendable {
  private let client: any ChatGPTImageServing

  public init(client: any ChatGPTImageServing) { self.client = client }

  public func prepare(source: ModelBinaryContent, layers: [Layer]) throws -> Plan {
    guard source.mimeType.lowercased() == "image/png" else {
      throw AgentError.invalidToolCall("Layer source must be a real PNG")
    }
    let raster = try ChatGPTImageRasterCodec.decode(source.data,
      maximumBytes: ChatGPTImageClient.maximumInputImageBytes, requireLayerColorContract: true)
    let plan = try Plan(sourceSHA256: SHA256HexDigest.digest(source.data), width: raster.width,
      height: raster.height, layers: layers)
    _ = try plan.encoded()
    return plan
  }

  /// Exactly one external edit per invocation. It never batches layers under one durable effect.
  /// A completed provider result is returned even if cancellation arrives during local processing;
  /// the kernel can persist it before honoring cancellation. No detached tasks are created.
  public func render(
    plan: Plan, layerID: String, source: ModelBinaryContent, turnID: UUID
  ) async throws -> Outcome {
    let layer: Layer
    let prompt: String
    do {
      guard !Task.isCancelled else { throw CancellationError() }
      let sourceSHA256 = SHA256HexDigest.digest(source.data)
      guard source.mimeType.lowercased() == "image/png",
        sourceSHA256 == plan.sourceSHA256,
        let selected = plan.layers.first(where: { $0.id == layerID }) else {
        throw AgentError.invalidToolCall("Layer source digest or layer identity does not match the plan")
      }
      let header = try ChatGPTPNGStructure.parse(source.data,
        maximumBytes: ChatGPTImageClient.maximumInputImageBytes)
      guard header.width == plan.width, header.height == plan.height else {
        throw AgentError.invalidToolCall("Layer plan canvas differs from its source")
      }
      // A decoded plan is only data. Recheck actual pixels/profile before spending a remote effect.
      _ = try ChatGPTImageRasterCodec.decode(source.data,
        maximumBytes: ChatGPTImageClient.maximumInputImageBytes, requireLayerColorContract: true)
      layer = selected
      prompt = try plan.prompt(for: layerID)
    } catch {
      throw EffectFailure.definiteFailure(operation: "images.layers.render.preflight", cause: error.localizedDescription)
    }
    guard !Task.isCancelled else {
      throw EffectFailure.definiteFailure(operation: "images.layers.render.preflight",
        cause: "Cancelled before layer dispatch")
    }
    let result: ChatGPTImageResult
    do {
      result = try await client.edit(.init(images: [ChatGPTImageContent(source)], prompt: prompt,
        background: layer.role == .background ? .auto : .transparent,
        quality: .high, size: "\(plan.width)x\(plan.height)", turnID: turnID))
    } catch {
      throw ChatGPTImagesToolPack.classifiedProviderFailure(error, operation: "images.layers.render")
    }
    // This limit precedes any attempt to persist a malformed response as a review artifact.
    guard !result.image.data.isEmpty, result.image.data.count <= ChatGPTImageClient.maximumImageBytes else {
      throw EffectFailure.outcomeUnknown(operation: "images.layers.render.publication",
        cause: "Provider returned an empty or oversized candidate", context: ["providerReturned": "true"])
    }
    do {
      guard result.image.mimeType.lowercased() == "image/png" else {
        throw AgentError.invalidToolCall("Layer provider returned a non-PNG candidate")
      }
      let raster = try ChatGPTImageRasterCodec.decode(result.image.data, requireLayerColorContract: true)
      guard raster.width == plan.width, raster.height == plan.height else {
        throw AgentError.invalidToolCall("Candidate changed the source canvas; resizing is not allowed")
      }
      guard raster.hasSubject, layer.role == .background || raster.hasClearPixels else {
        throw AgentError.invalidToolCall("Candidate is empty or lacks a genuinely clear region outside the element")
      }
      let exported = try raster.chromaExport()
      let png = try ChatGPTImageRasterCodec.encode(exported.raster)
      let planSHA256 = try plan.digest()
      guard let stackIndex = plan.layers.firstIndex(where: { $0.id == layer.id }) else {
        throw AgentError.invariantViolation("Rendered layer is absent from its immutable plan")
      }
      let rgbaSourceSHA256 = SHA256HexDigest.digest(result.image.data)
      let source = try RecompositionSource(layerID: layer.id, planSHA256: planSHA256,
        png: result.image.data, contentSHA256: rgbaSourceSHA256)
      let alphaAdmission: CandidateContractVerification.AlphaAdmission =
        layer.role == .background ? .backgroundHasSubject : .elementHasSubjectAndClearPixels
      let verification = CandidateContractVerification(
        sourceSHA256: plan.sourceSHA256, planSHA256: planSHA256, layerID: layer.id,
        stackIndex: stackIndex, width: plan.width, height: plan.height, alphaAdmission: alphaAdmission,
        rgbaSourceSHA256: rgbaSourceSHA256, chromaProjectionSHA256: SHA256HexDigest.digest(png))
      return .candidate(RenderedLayer(
        source: source, width: plan.width, height: plan.height,
        chromaImage: ModelBinaryContent(mimeType: "image/png", data: png, filename: "\(layer.id).png"),
        chromaKey: exported.key.rawValue, minimumSquaredRGBDistance: exported.minimumSquaredRGBDistance,
        providerRequestID: result.imageGenerationRequestID, turnID: turnID, verification: verification))
    } catch {
      // The remote effect is observed; retain its bounded bytes as a rejected candidate.
      // Never turn this into an automatic remote retry or a fictitious absent effect.
      return .rejected(RejectedCandidate(layerID: layer.id, bytes: result.image.data,
        reason: error.localizedDescription, providerImageSHA256: SHA256HexDigest.digest(result.image.data),
        providerRequestID: result.imageGenerationRequestID))
    }
  }

  /// Convenience preserving the existing public return type.
  public func recompose(plan: Plan, layers: [RenderedLayer]) throws -> ModelBinaryContent {
    try recomposeVerified(plan: plan, layers: layers).image
  }

  public func recomposeVerified(plan: Plan, layers: [RenderedLayer]) throws -> VerifiedRecomposition {
    try recomposeVerified(plan: plan, sources: layers.map(\.source))
  }

  /// Preserve the existing public return type while making deterministic verification available
  /// to callers that need evidence rather than only projected bytes.
  public func recompose(plan: Plan, sources: [RecompositionSource]) throws -> ModelBinaryContent {
    try recomposeVerified(plan: plan, sources: sources).image
  }

  /// Recompose persisted alpha sources in the immutable plan order. No semantic claim is made.
  public func recomposeVerified(plan: Plan, sources: [RecompositionSource]) throws -> VerifiedRecomposition {
    let digest = try plan.digest()
    guard sources.count == plan.layers.count,
      Set(sources.map(\.layerID)).count == sources.count,
      Set(sources.map(\.layerID)) == Set(plan.layers.map(\.id)),
      sources.allSatisfy({ $0.planSHA256 == digest }) else {
      throw AgentError.invalidToolCall("Recomposition requires exactly one source for each layer of this plan")
    }
    let indexed = Dictionary(uniqueKeysWithValues: sources.map { ($0.layerID, $0) })
    var composite = try ChatGPTLayerRaster(width: plan.width, height: plan.height,
      pixels: [UInt8](repeating: 0, count: plan.width * plan.height * 4))
    var orderedDigests: [String] = []
    for layer in plan.layers {
      guard let source = indexed[layer.id] else { throw AgentError.invalidToolCall("Missing planned layer") }
      let raster = try ChatGPTImageRasterCodec.decode(source.png, requireLayerColorContract: true)
      guard raster.width == plan.width, raster.height == plan.height, raster.hasSubject,
        layer.role == .background || raster.hasClearPixels else {
        throw AgentError.invalidToolCall("Stored alpha source violates the planned canvas or layer contract")
      }
      orderedDigests.append(source.contentSHA256)
      composite = try raster.composited(over: composite)
    }
    let data = try ChatGPTImageRasterCodec.encode(composite)
    let image = ModelBinaryContent(mimeType: "image/png", data: data, filename: "recomposed-candidates.png")
    let verification = RecompositionVerification(
      planSourceSHA256: plan.sourceSHA256, planSHA256: digest, width: plan.width, height: plan.height,
      layerIDsBackToFront: plan.layers.map(\.id), rgbaSourceSHA256sBackToFront: orderedDigests,
      outputSHA256: SHA256HexDigest.digest(data))
    return VerifiedRecomposition(image: image, verification: verification)
  }

  /// Immutable compressed alpha source, with exact byte identity and explicit plan binding.
  /// Digests establish integrity relative to host-owned metadata, not provenance authenticity.
  public struct RecompositionSource: Sendable {
    public let layerID: String
    public let planSHA256: String
    public let png: Data
    public let contentSHA256: String

    public init(layerID: String, planSHA256: String, png: Data, contentSHA256: String) throws {
      guard !layerID.isEmpty, layerID.utf8.count <= 64,
        layerID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
        planSHA256.utf8.count == 64,
        planSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        !png.isEmpty, png.count <= ChatGPTImageClient.maximumImageBytes,
        SHA256HexDigest.digest(png) == contentSHA256 else {
        throw AgentError.invalidToolCall("Stored alpha source identity or digest is invalid")
      }
      _ = try ChatGPTPNGStructure.parse(png)
      self.layerID = layerID
      self.planSHA256 = planSHA256
      self.png = png
      self.contentSHA256 = contentSHA256
    }
  }

  public enum Outcome: Sendable {
    /// Chroma/alpha/canvas contracts admitted; semantic fidelity is still unverified.
    case candidate(RenderedLayer)
    /// Provider returned bytes but framing, canvas or minimum alpha admission was not met.
    case rejected(RejectedCandidate)
  }

  public struct RenderedLayer: Sendable {
    /// Sole recomposition source; the chroma image below is a display/export projection.
    public let source: RecompositionSource
    public var layerID: String { source.layerID }
    public var planSHA256: String { source.planSHA256 }
    public let width: Int
    public let height: Int
    public let chromaImage: ModelBinaryContent
    public var rgbaSourcePNG: Data { source.png }
    public let chromaKey: String
    public let minimumSquaredRGBDistance: Int
    public var providerImageSHA256: String { source.contentSHA256 }
    public let providerRequestID: String?
    public let turnID: UUID
    public let verification: CandidateContractVerification
  }

  public struct RejectedCandidate: Sendable {
    public let layerID: String
    public let bytes: Data
    public let reason: String
    public let providerImageSHA256: String
    public let providerRequestID: String?
  }
}
