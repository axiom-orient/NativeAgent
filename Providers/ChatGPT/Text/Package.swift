// swift-tools-version: 6.2
import PackageDescription
let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "ChatGPTText",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "ChatGPTText", targets: ["ChatGPTText"])],
  dependencies: [
    .package(name: "ChatGPTAccount", path: "../Account"),
    .package(name: "LanguageModelCore", path: "../../../Model/LanguageModelCore")
  ],
  targets: [
    .target(
      name: "ChatGPTText",
      dependencies: [
        .product(name: "ChatGPTAccount", package: "ChatGPTAccount"),
        .product(name: "LanguageModelCore", package: "LanguageModelCore")
      ],
      swiftSettings: strict
    ),
    .testTarget(name: "ChatGPTTextTests", dependencies: ["ChatGPTText", "ChatGPTAccount", "LanguageModelCore"], swiftSettings: strict)
  ],
  swiftLanguageModes: [.v6]
)
