import CoreAILanguageModels
import Foundation
import FoundationModels
import LiteRTLM
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// iOS 27 local model factories. Foundation Models remains the session API;
/// Core AI, MLX and LiteRT remain the inference/tokenization authorities.
public enum AppleLocalAILocalModels {
  public static func coreAI(directory: URL) async throws -> CoreAILanguageModel {
    try Task.checkCancellation()
    try LocalModelAssetAdmission.validate(directory, as: .coreAI)
    let model = try await CoreAILanguageModel(resourcesAt: directory)
    do {
      try await model.load()
      try Task.checkCancellation()
      return model
    } catch {
      model.unload()
      throw error
    }
  }

  public static func mlx(
    directory: URL,
    capabilities: [LanguageModelCapabilities.Capability]
  ) throws -> MLXLanguageModel {
    let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    if LocalModelFileFormat.inspect(directory) == .gguf {
      throw LocalModelAssetError.unsupportedGGUF
    }

    let visionRequested = capabilities.contains(.vision)
    let visionBundle = LocalModelAsset.isMLXVLMModelDirectory(at: directory)
    guard visionRequested ? visionBundle : LocalModelAsset.isMLXModelDirectory(at: directory) else {
      throw visionRequested
        ? LocalLanguageModelError.invalidMLXVLMDirectory
        : LocalLanguageModelError.invalidMLXDirectory
    }

    return MLXLanguageModel(
      configuration: ModelConfiguration(
        id: directory.absoluteString,
        tokenizerSource: .directory(directory)
      ),
      capabilities: capabilities,
      weightsLocation: { _ in directory },
      load: { _, _ in
        try Task.checkCancellation()
        if visionBundle {
          return try await VLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
          )
        }
        return try await loadModelContainer(
          from: directory,
          using: #huggingFaceTokenizerLoader()
        )
      }
    )
  }

  /// Uses LiteRT-LM's official core runtime through the repository's narrow
  /// Foundation Models compatibility boundary. Foundation Models still owns
  /// the session and transcript; this adapter only translates supported
  /// transcript segments and forwards cancellation to LiteRT.
  public static func liteRT(
    configuration: LiteRTConfiguration
  ) throws -> LiteRTLanguageModel {
    let url = configuration.modelURL.standardizedFileURL.resolvingSymlinksInPath()
    if LocalModelFileFormat.inspect(url) == .gguf {
      throw LocalModelAssetError.unsupportedGGUF
    }
    try LocalModelAssetAdmission.validate(url, as: .liteRT)

    guard let capabilities = LiteRTModelInspector.capabilities(for: url) else {
      throw LiteRTConfigurationError.invalidCapabilities
    }
    guard capabilities.supportsText else {
      throw LiteRTConfigurationError.textUnavailable
    }
    if configuration.visionBackend != .disabled, !capabilities.supportsVision {
      throw LiteRTConfigurationError.visionUnavailable
    }

    return try LiteRTLanguageModel(
      modelPath: url.path,
      backend: configuration.backend.nativeValue,
      visionBackend: configuration.visionBackend.nativeValue,
      visualTokenBudget: nil,
      maxTokens: nil,
      cacheDir: nil
    )
  }

  /// Call only at an idle model-switch boundary.
  public static func releaseMLXResources() async {
    await MLXLanguageModel.evictAll()
  }

  /// Call only at an idle model-switch boundary.
  public static func releaseLiteRTResources() async {
    await LiteRTLanguageModel.releaseCachedEngines()
  }
}

extension LiteRTBackendChoice {
  fileprivate var nativeValue: Backend {
    switch self {
    case .cpu: .cpu()
    case .gpu: .gpu
    }
  }
}

extension LiteRTVisionBackendChoice {
  fileprivate var nativeValue: Backend? {
    switch self {
    case .disabled: nil
    case .cpu: .cpu()
    case .gpu: .gpu
    }
  }
}

public enum LocalLanguageModelError: Error, LocalizedError, Sendable {
  case invalidMLXDirectory
  case invalidMLXVLMDirectory

  public var errorDescription: String? {
    switch self {
    case .invalidMLXDirectory:
      "Choose an MLX model directory with config.json, tokenizer.json and non-empty safetensors weights."
    case .invalidMLXVLMDirectory:
      "Choose an MLXVLM directory with vision metadata, tokenizer.json and non-empty safetensors weights."
    }
  }
}
