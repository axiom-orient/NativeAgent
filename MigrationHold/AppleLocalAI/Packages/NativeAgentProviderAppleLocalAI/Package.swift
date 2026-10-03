// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "NativeAgentProviderAppleLocalAI",
  platforms: [.iOS("27.0"), .macOS("27.0")],
  products: [.library(name: "NativeAgentProviderAppleLocalAI", targets: ["NativeAgentProviderAppleLocalAI"])],
  dependencies: [
    .package(name: "LanguageModelCore", path: "../../../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../../../Model/LanguageModelRuntime"),
    .package(name: "AppleLocalAI", path: "../.."),
  ],
  targets: [
    .target(
      name: "NativeAgentProviderAppleLocalAI",
      dependencies: [
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
        .product(name: "AppleLocalAI", package: "AppleLocalAI"),
      ]
    ),
    .testTarget(
      name: "NativeAgentProviderAppleLocalAITests",
      dependencies: [
        "NativeAgentProviderAppleLocalAI",
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
        .product(name: "AppleLocalAI", package: "AppleLocalAI"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
