// swift-tools-version: 6.2
import PackageDescription
let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "ChatGPTAccount",
  platforms: [.iOS(.v17)],
  products: [.library(name: "ChatGPTAccount", targets: ["ChatGPTAccount"])],
  dependencies: [

  ],
  targets: [
    .target(
      name: "ChatGPTAccount",
      dependencies: [

      ],
      swiftSettings: strict
    ),
    .testTarget(name: "ChatGPTAccountTests", dependencies: ["ChatGPTAccount"], swiftSettings: strict)
  ],
  swiftLanguageModes: [.v6]
)
