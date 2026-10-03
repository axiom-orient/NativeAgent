// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "MLXProvider",
  platforms: [.iOS(.v17), .macOS(.v15)],
  products: [
    .library(name: "MLXProvider", targets: ["MLXProvider"]),
    .library(name: "MLXModelRegistry", targets: ["MLXModelRegistry"]),
  ],
  dependencies: [
    .package(name: "LanguageModelCore", path: "../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../Model/LanguageModelRuntime"),
    .package(name: "ModelArtifactStore", path: "../../Model/ModelArtifactStore"),
    .package(name: "ModelHub", path: "../../Model/ModelHub"),
    .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.10.2", traits: []),
    .package(
      url: "https://github.com/ml-explore/mlx-swift",
      revision: "901941965d82e4a216d4d117231d847d194c563d"),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      revision: "c6446cf7bfb7cea76408013b614d4b2c530eaa03", traits: []),
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
  ],
  targets: [
    .target(
      name: "MLXModelRegistry",
      dependencies: [
        .product(name: "ModelArtifactStore", package: "ModelArtifactStore"),
        .product(name: "ModelHub", package: "ModelHub"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
      ],
      swiftSettings: strict
    ),
    .target(
      name: "MLXProvider",
      dependencies: [
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
        .product(name: "ModelArtifactStore", package: "ModelArtifactStore"),
        .product(name: "ModelHub", package: "ModelHub"),
        "MLXModelRegistry",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "MLXModelRegistryTests",
      dependencies: [
        "MLXModelRegistry",
        .product(name: "ModelArtifactStore", package: "ModelArtifactStore"),
        .product(name: "ModelHub", package: "ModelHub"),
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "MLXProviderTests",
      dependencies: [
        "MLXProvider",
        "MLXModelRegistry",
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
        .product(name: "ModelArtifactStore", package: "ModelArtifactStore"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
      ],
      swiftSettings: strict
    ),
  ],
  swiftLanguageModes: [.v6]
)
