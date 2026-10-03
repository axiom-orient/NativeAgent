// swift-tools-version: 6.2
import PackageDescription
let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "ChatGPTImage",
  platforms: [.iOS(.v17)],
  products: [.library(name: "ChatGPTImage", targets: ["ChatGPTImage"])],
  dependencies: [
    .package(name: "ChatGPTAccount", path: "../Account")
  ],
  targets: [
    .target(
      name: "ChatGPTImage",
      dependencies: [
        .product(name: "ChatGPTAccount", package: "ChatGPTAccount")
      ],
      swiftSettings: strict
    ),
    .testTarget(name: "ChatGPTImageTests", dependencies: ["ChatGPTImage", "ChatGPTAccount"], swiftSettings: strict)
  ],
  swiftLanguageModes: [.v6]
)
