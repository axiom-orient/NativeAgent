// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "LiteRTUnifiedQualification",
  platforms: [.iOS(.v17), .macOS(.v15)],
  dependencies: [
    .package(name: "LiteRTProvider", path: "../../Providers/LiteRT"),
    .package(name: "LiteRTEmbeddingProvider", path: "../../Providers/LiteRTEmbedding"),
    .package(name: "LanguageModelCore", path: "../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../Model/LanguageModelRuntime"),
    .package(name: "EmbeddingCore", path: "../../Model/EmbeddingCore"),
  ],
  targets: [
    .target(name: "LiteRTUnifiedQualification", dependencies: [
      .product(name: "LiteRTProvider", package: "LiteRTProvider"),
      .product(name: "LiteRTEmbeddingProvider", package: "LiteRTEmbeddingProvider"),
      .product(name: "LanguageModelCore", package: "LanguageModelCore"),
      .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
      .product(name: "EmbeddingCore", package: "EmbeddingCore"),
    ], path: "Shared"),
    .executableTarget(name: "LiteRTUnifiedCLI", dependencies: ["LiteRTUnifiedQualification",
      .product(name: "LiteRTProvider", package: "LiteRTProvider")], path: "CLI"),
  ], swiftLanguageModes: [.v6]
)
