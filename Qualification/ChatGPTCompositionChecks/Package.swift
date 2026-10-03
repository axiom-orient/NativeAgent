// swift-tools-version: 6.2
import PackageDescription
let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "ChatGPTCompositionChecks",
  platforms: [.iOS(.v17), .macOS(.v15)],
  dependencies: [
    .package(path: "../../Agent/NativeAgentPackage/Packages/ChatGPTAgent"),
    .package(name: "ChatGPTAccount", path: "../../Providers/ChatGPT/Account"),
    .package(name: "ChatGPTText", path: "../../Providers/ChatGPT/Text"),
    .package(name: "ChatGPTImage", path: "../../Providers/ChatGPT/Image"),
    .package(name: "ChatGPTTextProvider", path: "../../Providers/ChatGPT/TextProvider"),
    .package(name: "ChatGPTImageCapability", path: "../../Agent/NativeAgentPackage/Packages/ChatGPTImageCapability"),
    .package(name: "NativeAgentPackage", path: "../../Agent/NativeAgentPackage"),
    .package(name: "LanguageModelCore", path: "../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../Model/LanguageModelRuntime")
  ],
  targets: [.testTarget(name: "ChatGPTCompositionTests", dependencies: [
    .product(name: "ChatGPTAgent", package: "ChatGPTAgent"),
    .product(name: "ChatGPTAccount", package: "ChatGPTAccount"),
    .product(name: "ChatGPTText", package: "ChatGPTText"),
    .product(name: "ChatGPTImage", package: "ChatGPTImage"),
    .product(name: "ChatGPTTextProvider", package: "ChatGPTTextProvider"),
    .product(name: "ChatGPTImageCapability", package: "ChatGPTImageCapability"),
    .product(name: "LanguageModelCore", package: "LanguageModelCore"),
    .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
    .product(name: "NativeAgent", package: "NativeAgentPackage"),
    .product(name: "NativeAgentDomain", package: "NativeAgentPackage"),
    .product(name: "NativeAgentTools", package: "NativeAgentPackage"),
    .product(name: "NativeAgentManager", package: "NativeAgentPackage"),
    .product(name: "NativeAgentSkills", package: "NativeAgentPackage"),
    .product(name: "NativeAgentMemory", package: "NativeAgentPackage"),
    .product(name: "NativeAgentGoals", package: "NativeAgentPackage"),
    .product(name: "NativeAgentEvolution", package: "NativeAgentPackage"),
    .product(name: "NativeAgentConsensus", package: "NativeAgentPackage")
  ], swiftSettings: strict)],
  swiftLanguageModes: [.v6]
)
