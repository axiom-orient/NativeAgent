// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures"),
]
let package = Package(
  name: "ChatGPTAgent", platforms: [.iOS(.v17)],
  products: [.library(name: "ChatGPTAgent", targets: ["ChatGPTAgent"])],
  dependencies: [
    .package(name: "NativeAgentPackage", path: "../.."),
    .package(name: "ChatGPTAccount", path: "../../../../Providers/ChatGPT/Account"),
    .package(name: "ChatGPTTextProvider", path: "../../../../Providers/ChatGPT/TextProvider"),
    .package(name: "LanguageModelRuntime", path: "../../../../Model/LanguageModelRuntime"),
  ],
  targets: [
    .target(
      name: "ChatGPTAgent",
      dependencies: [
        .product(name: "NativeAgent", package: "NativeAgentPackage"),
        .product(name: "NativeAgentDomain", package: "NativeAgentPackage"),
        .product(name: "NativeAgentManager", package: "NativeAgentPackage"),
        .product(name: "NativeAgentSkills", package: "NativeAgentPackage"),
        .product(name: "ChatGPTAccount", package: "ChatGPTAccount"),
        .product(name: "ChatGPTTextProvider", package: "ChatGPTTextProvider"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
      ], swiftSettings: strict)
  ], swiftLanguageModes: [.v6]
)
