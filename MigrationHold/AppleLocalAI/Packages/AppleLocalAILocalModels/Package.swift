// swift-tools-version: 6.4
import PackageDescription
let package = Package(
  name: "AppleLocalAILocalModels",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [.library(name: "AppleLocalAILocalModels", targets: ["AppleLocalAILocalModels"])],
  dependencies: [
    .package(
      url: "https://github.com/apple/coreai-models",
      revision: "3f109efd54273391f9fd9f5f5b3d8c6e99836d55"
    ),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      revision: "c6446cf7bfb7cea76408013b614d4b2c530eaa03"
    ),
    // Xcode 27's iOS Metal compiler requires the thread address-space fixes
    // present after the 0.31.6 tag.
    .package(
      url: "https://github.com/ml-explore/mlx-swift",
      revision: "901941965d82e4a216d4d117231d847d194c563d"
    ),
    .package(
      url: "https://github.com/huggingface/swift-transformers",
      exact: "1.3.4"
    ),
    .package(
      url: "https://github.com/google-ai-edge/LiteRT-LM",
      exact: "0.17.1"
    ),
  ],
  targets: [
    .target(
      name: "AppleLocalAILocalModels",
      dependencies: [
        .product(name: "CoreAILM", package: "coreai-models"),
        .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
        .product(name: "MLXVLM", package: "mlx-swift-lm"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "LiteRTLM", package: "LiteRT-LM"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
