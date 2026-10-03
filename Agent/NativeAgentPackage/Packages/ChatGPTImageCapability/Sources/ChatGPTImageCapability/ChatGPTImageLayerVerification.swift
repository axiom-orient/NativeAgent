import Foundation
import LanguageModelCore

extension ChatGPTImageLayers {
  /// Evidence created only after the provider result has passed the local, deterministic
  /// layer contract. Its existence does not claim semantic/source visual fidelity.
  public struct CandidateContractVerification: Hashable, Sendable {
    public enum AlphaAdmission: String, Hashable, Sendable {
      case backgroundHasSubject = "background_has_subject"
      case elementHasSubjectAndClearPixels = "element_has_subject_and_clear_pixels"
    }

    /// Exact source digest observed and matched to the plan before provider dispatch.
    public let sourceSHA256: String
    public let planSHA256: String
    public let layerID: String
    public let stackIndex: Int
    public let width: Int
    public let height: Int
    public let alphaAdmission: AlphaAdmission
    public let rgbaSourceSHA256: String
    public let chromaProjectionSHA256: String
    public let stackOrder: String

    public var status: String { "verified" }

    internal init(
      sourceSHA256: String,
      planSHA256: String,
      layerID: String,
      stackIndex: Int,
      width: Int,
      height: Int,
      alphaAdmission: AlphaAdmission,
      rgbaSourceSHA256: String,
      chromaProjectionSHA256: String
    ) {
      self.sourceSHA256 = sourceSHA256
      self.planSHA256 = planSHA256
      self.layerID = layerID
      self.stackIndex = stackIndex
      self.width = width
      self.height = height
      self.alphaAdmission = alphaAdmission
      self.rgbaSourceSHA256 = rgbaSourceSHA256
      self.chromaProjectionSHA256 = chromaProjectionSHA256
      self.stackOrder = "back_to_front"
    }
  }

  /// Evidence that persisted alpha sources passed plan/canvas/alpha admission and were
  /// composited exactly in the plan's back-to-front order. Provenance and semantics are separate.
  public struct RecompositionVerification: Hashable, Sendable {
    /// Source digest declared by the immutable plan. Recomposition does not independently
    /// re-prove that persisted layer bytes originated from that source image.
    public let planSourceSHA256: String
    public let planSHA256: String
    public let width: Int
    public let height: Int
    public let layerIDsBackToFront: [String]
    public let rgbaSourceSHA256sBackToFront: [String]
    public let outputSHA256: String
    public let stackOrder: String

    public var status: String { "verified" }

    internal init(
      planSourceSHA256: String,
      planSHA256: String,
      width: Int,
      height: Int,
      layerIDsBackToFront: [String],
      rgbaSourceSHA256sBackToFront: [String],
      outputSHA256: String
    ) {
      self.planSourceSHA256 = planSourceSHA256
      self.planSHA256 = planSHA256
      self.width = width
      self.height = height
      self.layerIDsBackToFront = layerIDsBackToFront
      self.rgbaSourceSHA256sBackToFront = rgbaSourceSHA256sBackToFront
      self.outputSHA256 = outputSHA256
      self.stackOrder = "back_to_front"
    }
  }

  public struct VerifiedRecomposition: Sendable {
    public let image: ModelBinaryContent
    public let verification: RecompositionVerification

    internal init(image: ModelBinaryContent, verification: RecompositionVerification) {
      self.image = image
      self.verification = verification
    }
  }
}
