// swift-tools-version: 6.2
import PackageDescription
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
let package = Package(
  name: "LEAPProvider",
  platforms: [.iOS(.v17)],
  products: [.library(name: "LEAPProvider", targets: ["LEAPProvider"])],
  dependencies: [
    .package(name: "NativeAILeapSDK", path: "Packages/NativeAILeapSDK"),
    .package(name: "LanguageModelCore", path: "../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../Model/LanguageModelRuntime"),
    .package(name: "ModelArtifactStore", path: "../../Model/ModelArtifactStore"),
    .package(name: "ModelHub", path: "../../Model/ModelHub"),
    .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.10.2", traits: []),
  ],
  targets: [

    .target(name: "LEAPProvider", dependencies: [
      .product(name: "LanguageModelCore", package: "LanguageModelCore"),
      .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
      .product(name: "ModelArtifactStore", package: "ModelArtifactStore"),
      .product(name: "ModelHub", package: "ModelHub"),
      .product(name: "HuggingFace", package: "swift-huggingface"),
      .product(name: "LeapSDK", package: "NativeAILeapSDK"),
    ], swiftSettings: strict),
    .testTarget(name: "LEAPProviderTests", dependencies: [
      "LEAPProvider",
      .product(name: "LeapSDK", package: "NativeAILeapSDK"),
      .product(name: "LanguageModelCore", package: "LanguageModelCore"),
      .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
      .product(name: "ModelArtifactStore", package: "ModelArtifactStore"),
      .product(name: "ModelHub", package: "ModelHub"),
      .product(name: "HuggingFace", package: "swift-huggingface"),
    ], swiftSettings: strict),
  ],
  swiftLanguageModes: [.v6]
)
