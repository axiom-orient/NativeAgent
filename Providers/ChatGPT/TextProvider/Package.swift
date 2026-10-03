// swift-tools-version: 6.2
import PackageDescription
let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "ChatGPTTextProvider",
  platforms: [.iOS(.v17)],
  products: [.library(name: "ChatGPTTextProvider", targets: ["ChatGPTTextProvider"])],
  dependencies: [
    .package(name: "ChatGPTAccount", path: "../Account"),
    .package(name: "ChatGPTText", path: "../Text"),
    .package(name: "LanguageModelCore", path: "../../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../../Model/LanguageModelRuntime")
  ],
  targets: [
    .target(
      name: "ChatGPTTextProvider",
      dependencies: [
        .product(name: "ChatGPTAccount", package: "ChatGPTAccount"),
        .product(name: "ChatGPTText", package: "ChatGPTText"),
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime")
      ],
      swiftSettings: strict
    )
  ],
  swiftLanguageModes: [.v6]
)
