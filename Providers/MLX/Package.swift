// swift-tools-version: 6.3
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
    .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.13.0", traits: []),
    .package(
      url: "https://github.com/ml-explore/mlx-swift",
      exact: "0.32.3"),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      exact: "3.32.3", traits: []),
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
