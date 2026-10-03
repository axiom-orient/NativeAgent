import ModelArtifactStore
import Foundation

public enum LeapEnglishVoice: String, CaseIterable, Codable, Hashable, Sendable {
  case usMale
  case usFemale
  case ukMale
  case ukFemale

  var systemPrompt: String {
    switch self {
    case .usMale: "Perform TTS. Use the US male voice."
    case .usFemale: "Perform TTS. Use the US female voice."
    case .ukMale: "Perform TTS. Use the UK male voice."
    case .ukFemale: "Perform TTS. Use the UK female voice."
    }
  }
}

public struct LeapAudioInput: Hashable, Sendable {
  public let samples: [Float]
  public let sampleRate: Int

  public init(samples: [Float], sampleRate: Int) throws {
    guard LeapRequestLimits.sampleRates.contains(sampleRate), !samples.isEmpty,
      samples.count <= sampleRate * LeapRequestLimits.maximumAudioSeconds,
      samples.allSatisfy({ $0.isFinite && (-1...1).contains($0) })
    else { throw LeapError.invalidRequest }
    self.samples = samples
    self.sampleRate = sampleRate
  }
}

public enum LeapVoiceRequest: Hashable, Sendable {
  case transcribeEnglish(audio: LeapAudioInput)
  case synthesizeEnglish(text: String, voice: LeapEnglishVoice)
  case speechToSpeechEnglish(audio: LeapAudioInput)

  public func validate() throws {
    switch self {
    case .transcribeEnglish, .speechToSpeechEnglish:
      // LeapAudioInput is immutable and validates the complete PCM buffer at
      // construction time. Reconstructing it here would scan every sample a
      // second time (and needlessly risk a copy) before every native request.
      break
    case .synthesizeEnglish(let text, _):
      let bytes = text.utf8.count
      guard (1...LeapRequestLimits.maximumTextUTF8Bytes).contains(bytes),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        text.unicodeScalars.allSatisfy({ $0.isASCII })
      else { throw LeapError.unsupportedLanguageOrCapability }
    }
  }
}

public struct LeapVoiceUsage: Hashable, Sendable {
  public let promptTokens: Int64?
  public let completionTokens: Int64?
  public let tokensPerSecond: Float?

  public init(promptTokens: Int64?, completionTokens: Int64?, tokensPerSecond: Float?) throws {
    guard promptTokens.map({ $0 >= 0 }) ?? true,
      completionTokens.map({ $0 >= 0 }) ?? true,
      tokensPerSecond.map({ $0.isFinite && $0 >= 0 }) ?? true
    else { throw LeapError.invalidRuntimeOutput }
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.tokensPerSecond = tokensPerSecond
  }
}

public enum LeapVoiceEvent: Hashable, Sendable {
  case transcriptDelta(String)
  case textDelta(String)
  case pcm(samples: [Float], sampleRate: Int)
  case completed(LeapVoiceUsage)
}

public enum LeapReadiness: Equatable, Sendable { case missing, ready, busy }

public enum LeapError: Error, Equatable, Sendable {
  case invalidRequest
  case unsupportedLanguageOrCapability
  case modelMissing
  case busy
  case insufficientDisk
  case invalidArtifact
  case invalidRuntimeOutput
  case outputLimitExceeded
  case generationInterrupted
  case generationTimedOut
  case generationStalled
  case nativeFailure
}

extension LeapError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidRequest: "The audio or text request is invalid."
    case .unsupportedLanguageOrCapability: "The requested language or capability is not supported."
    case .modelMissing: "The pinned model is not installed."
    case .busy: "The LEAP runtime is busy."
    case .insufficientDisk: "There is not enough storage for the model."
    case .invalidArtifact: "The installed model failed integrity validation."
    case .invalidRuntimeOutput: "The LEAP runtime returned an invalid response."
    case .outputLimitExceeded: "The response exceeded its output limit."
    case .generationInterrupted: "The response was interrupted before completion."
    case .generationTimedOut: "The response exceeded its total time limit."
    case .generationStalled: "The response stopped making progress."
    case .nativeFailure: "The LEAP runtime failed."
    }
  }
}

extension LeapError: CustomNSError {
  public static let errorDomain = "com.axiomorient.nativeagent.leap"

  /// Stable machine-readable name for logs and UI presentation boundaries.
  public var stableCode: String {
    switch self {
    case .invalidRequest: "invalidRequest"
    case .unsupportedLanguageOrCapability: "unsupportedLanguageOrCapability"
    case .modelMissing: "modelMissing"
    case .busy: "busy"
    case .insufficientDisk: "insufficientDisk"
    case .invalidArtifact: "invalidArtifact"
    case .invalidRuntimeOutput: "invalidRuntimeOutput"
    case .outputLimitExceeded: "outputLimitExceeded"
    case .generationInterrupted: "generationInterrupted"
    case .generationTimedOut: "generationTimedOut"
    case .generationStalled: "generationStalled"
    case .nativeFailure: "nativeFailure"
    }
  }

  public var errorCode: Int {
    switch self {
    case .invalidRequest: 1_001
    case .unsupportedLanguageOrCapability: 1_002
    case .modelMissing: 1_003
    case .busy: 1_004
    case .insufficientDisk: 1_005
    case .invalidArtifact: 1_006
    case .invalidRuntimeOutput: 1_007
    case .outputLimitExceeded: 1_008
    case .generationInterrupted: 1_009
    case .generationTimedOut: 1_010
    case .generationStalled: 1_011
    case .nativeFailure: 1_012
    }
  }

  public var errorUserInfo: [String: Any] {
    [
      NSLocalizedDescriptionKey: errorDescription ?? "The LEAP runtime failed.",
      "NativeAgentLeapCode": stableCode,
    ]
  }
}

/// Admission policy, separate from the generated-output budgets below.
enum LeapRequestLimits {
  static let sampleRates = 8_000...96_000
  static let maximumAudioSeconds = 60
  static let maximumTextUTF8Bytes = 16_384
}

/// Bounds that are part of the package's native-generation safety contract.
///
/// The token cap is passed to LEAP's official `GenerationOptions` API. The
/// byte/sample caps remain enforced on the response stream because native
/// completion metadata is not a substitute for validating emitted payloads.
enum LeapLimits {
  // Device evidence: generation past ~512 audio tokens (about 40 seconds) is
  // killed by the native engine, so this budget stays the per-request ceiling
  // and callers segment longer documents (see package README). Utterance
  // length also varies per native sampler draw, so budgets carry headroom.
  static let maxGenerationTokens: Int32 = 512
  // Device evidence (crash log): the audio detokenizer aborts the PROCESS when
  // a single request decodes toward the ceiling - the Swift-side token cap can
  // lose that race. Cutting consumption at 384 chunks (75% of the observed
  // survivable 511) turns the native abort into a structured error that the
  // caller's segmentation recovery handles.
  static let maxOutputChunks = 384
  static let maxTextBytes = 16_384
  static let maxOutputSeconds = 120
  static let maxRepeatedTextChunks = 4
  static let maxResponseEvents = 2_048
  // Text-only GGUF generation bounds. Text tokens do not reach the audio
  // detokenizer, so the text path can use a materially larger budget than the
  // voice ceiling while retaining finite memory and event protection.
  static let textContextTokens: UInt32 = 8_192
  static let maxTextGenerationTokens: Int32 = 4_096
  static let maxTextGenerationBytes = 128 * 1_024
  static let maxTextChunks = 8_192
}

private enum LeapModelValidation {
  static func repositoryID(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    return parts.allSatisfy { part in
      (1...96).contains(part.utf8.count)
        && part.unicodeScalars.allSatisfy {
          ($0.value >= 48 && $0.value <= 57)
            || ($0.value >= 65 && $0.value <= 90)
            || ($0.value >= 97 && $0.value <= 122)
            || $0.value == 45 || $0.value == 46 || $0.value == 95
        }
    }
  }

  static func revision(_ value: String) -> Bool {
    value.utf8.count == 40
      && value.unicodeScalars.allSatisfy {
        ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
      }
  }
}

/// An immutable, verified text-model contract.
///
/// A text runner is identified by both the complete artifact manifest digest
/// and the selected `.gguf` path.  Repository and revision are retained as
/// provenance, but they are not a substitute for the verified local manifest.
public struct LeapTextModel: Hashable, Sendable {
  public let repositoryID: String
  public let revision: String
  public let manifest: ArtifactManifest
  public let modelPath: String
  public let displayName: String?

  public var manifestDigest: ArtifactDigest { manifest.manifestDigest }
  public var identity: LeapTextModelIdentity {
    .init(manifestDigest: manifestDigest, modelPath: modelPath)
  }

  public init(
    repositoryID: String,
    revision: String,
    modelPath: String,
    manifest: ArtifactManifest,
    displayName: String? = nil
  ) throws {
    guard LeapModelValidation.repositoryID(repositoryID), LeapModelValidation.revision(revision),
      modelPath.hasSuffix(".gguf"),
      manifest.files.count == 1,
      manifest.files.contains(where: { $0.path == modelPath }),
      displayName.map({
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
      }) ?? true
    else { throw LeapError.invalidRequest }
    do { try manifest.validate() } catch { throw LeapError.invalidArtifact }
    self.repositoryID = repositoryID
    self.revision = revision.lowercased()
    self.manifest = manifest
    self.modelPath = modelPath
    self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

}

public struct LeapTextModelIdentity: Hashable, Sendable {
  public let manifestDigest: ArtifactDigest
  public let modelPath: String

  fileprivate init(manifestDigest: ArtifactDigest, modelPath: String) {
    self.manifestDigest = manifestDigest
    self.modelPath = modelPath
  }
}

/// Proof that a text model's exact manifest was prepared and verified before load.
///
/// Callers can inspect the immutable model identity but cannot construct this value
/// directly. `LeapRuntime.prepare(_:)` and `importModel(_:from:)` are the only
/// public creation paths. A receiving runtime still re-opens the verified artifact
/// from its own ArtifactStore, so a stale or foreign token fails closed.
public struct LeapPreparedTextModel: Hashable, Sendable {
  public let identity: LeapTextModelIdentity
  let model: LeapTextModel

  init(model: LeapTextModel) {
    self.identity = model.identity
    self.model = model
  }
}

/// Pinned managed text model metadata.  The package never asks LEAP to fetch
/// this model itself; `prepare` downloads these exact manifest entries through
/// `ModelArtifactStore` and the package downloader.
private enum LeapQADPin {
  static let repositoryID = "LiquidAI/LFM2.5-2.6B-GGUF"
  static let revision = "84022ce711b28455e8c4fc364ce68c00cf995875"
  static let modelPath = "LFM2.5-2.6B-QAD-Q4_0.gguf"
  static let byteCount: UInt64 = 1_593_894_944
  static let sha256 = "a247afd6414918eac8e520a9e6137dc271235461ecbe1180462221d5b8d40b03"
  static let manifest: ArtifactManifest = {
    let digest = ArtifactDigest(rawValue: sha256)!
    let entry = try! ArtifactEntry(path: modelPath, byteCount: byteCount, sha256: digest)
    return try! ArtifactManifest(
      artifactID: "leap-lfm2.5-2.6b-qad-q4_0-\(revision)", files: [entry])
  }()
}

private enum LeapQAD1_2BPin {
  static let repositoryID = "LiquidAI/LFM2.5-1.2B-Instruct-GGUF"
  static let revision = "6767265158422fb8a19c62ceb45f16f05363615b"
  static let modelPath = "LFM2.5-1.2B-Instruct-QAD-Q4_0.gguf"
  static let byteCount: UInt64 = 695_755_488
  static let sha256 = "bb741ebb106d543e9de114b843a3d3d73d51c74b5801e69da2abde821a0cb3e1"
  static let manifest: ArtifactManifest = {
    let digest = ArtifactDigest(rawValue: sha256)!
    let entry = try! ArtifactEntry(path: modelPath, byteCount: byteCount, sha256: digest)
    return try! ArtifactManifest(
      artifactID: "leap-lfm2.5-1.2b-instruct-qad-q4_0-\(revision)", files: [entry])
  }()
}

extension LeapTextModel {
  /// Default on-device text model: LiquidAI LFM2.5-1.2B Instruct QAD Q4_0.
  /// Explicitly selected checkpoints retain their own immutable identities.
  public static let `default`: Self = .qad1_2B

  /// The immutable LiquidAI LFM2.5-2.6B QAD Q4_0 checkpoint.
  public static let qad: Self = try! Self(
    repositoryID: LeapQADPin.repositoryID,
    revision: LeapQADPin.revision,
    modelPath: LeapQADPin.modelPath,
    manifest: LeapQADPin.manifest)

  /// The immutable LiquidAI LFM2.5-1.2B Instruct QAD Q4_0 checkpoint.
  public static let qad1_2B: Self = try! Self(
    repositoryID: LeapQAD1_2BPin.repositoryID,
    revision: LeapQAD1_2BPin.revision,
    modelPath: LeapQAD1_2BPin.modelPath,
    manifest: LeapQAD1_2BPin.manifest)
}

/// Immutable identity for the packaged English audio checkpoint.
public struct LeapVoiceModelIdentity: Hashable, Sendable {
  public let repositoryID: String
  public let revision: String
  public let manifestDigest: ArtifactDigest

  fileprivate init(repositoryID: String, revision: String, manifestDigest: ArtifactDigest) {
    self.repositoryID = repositoryID
    self.revision = revision
    self.manifestDigest = manifestDigest
  }
}

/// Explicit voice model selection.  The runtime never stores or assumes a
/// voice model; callers pass this contract to each lifecycle operation.
public struct LeapVoiceModel: Hashable, Sendable {
  public let repositoryID: String
  public let revision: String
  public let manifest: ArtifactManifest

  public var manifestDigest: ArtifactDigest { manifest.manifestDigest }
  public var identity: LeapVoiceModelIdentity {
    .init(repositoryID: repositoryID, revision: revision, manifestDigest: manifestDigest)
  }

  public init(
    repositoryID: String,
    revision: String,
    manifest: ArtifactManifest
  ) throws {
    guard LeapModelValidation.repositoryID(repositoryID), LeapModelValidation.revision(revision) else {
      throw LeapError.invalidRequest
    }
    do { try manifest.validate() } catch { throw LeapError.invalidArtifact }
    self.repositoryID = repositoryID
    self.revision = revision
    self.manifest = manifest
  }

  /// The exact audio model used by the live LEAP adapter.
  public static let pinned: Self = try! Self(
    repositoryID: "LiquidAI/LFM2.5-Audio-1.5B-GGUF-LEAP",
    revision: "d78ca1db4adae8be7a7dbab003d128abdb5b94c6",
    manifest: LeapVoiceModel.pinnedManifest)

  private static let pinnedManifest: ArtifactManifest = {
    try! ArtifactManifest(
      artifactID: "leap-lfm2.5-audio-1.5b-q4_0-d78ca1db4adae8be7a7dbab003d128abdb5b94c6",
      files: [
        entry(
          "LFM2.5-Audio-1.5B-Q4_0.gguf", 695_750_880,
          "3583bee853be20331ca342b0593fefd8acc43fb61a41ec6f1a1dc7465823e0d8"),
        entry(
          "mmproj-LFM2.5-Audio-1.5B-Q4_0.gguf", 219_511_136,
          "222ebe9c595d78d2e75881e2427580edd93f5544d5bd875a29677f63687d7148"),
        entry(
          "vocoder-LFM2.5-Audio-1.5B-Q4_0.gguf", 148_508_512,
          "7383a3c0af64ad10cfebf50eb88bc72b826dca79b0bd59c7fd65b0d6c904b0a7"),
      ])
  }()

  private static func entry(_ path: String, _ byteCount: UInt64, _ sha256: String)
    -> ArtifactEntry
  {
    try! ArtifactEntry(
      path: path, byteCount: byteCount, sha256: ArtifactDigest(rawValue: sha256)!)
  }

}
