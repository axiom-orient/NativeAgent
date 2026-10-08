// swift-tools-version: 6.2
import PackageDescription
let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "ChatGPTImageCapability",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "ChatGPTImageCapability", targets: ["ChatGPTImageCapability"])],
  dependencies: [
    .package(name: "NativeAgentPackage", path: "../.."),
    .package(name: "ChatGPTAccount", path: "../../../../Providers/ChatGPT/Account"),
    .package(name: "ChatGPTImage", path: "../../../../Providers/ChatGPT/Image"),
    .package(name: "LanguageModelCore", path: "../../../../Model/LanguageModelCore")
  ],
  targets: [
    .target(
      name: "ChatGPTImageCapability",
      dependencies: [
        .product(name: "NativeAgentDomain", package: "NativeAgentPackage"),
        .product(name: "NativeAgentSkills", package: "NativeAgentPackage"),
        .product(name: "ChatGPTAccount", package: "ChatGPTAccount"),
        .product(name: "ChatGPTImage", package: "ChatGPTImage"),
        .product(name: "LanguageModelCore", package: "LanguageModelCore")
      ],
      resources: [.copy("Resources/ImageCatalog")],
      swiftSettings: strict
    )
  ],
  swiftLanguageModes: [.v6]
)
