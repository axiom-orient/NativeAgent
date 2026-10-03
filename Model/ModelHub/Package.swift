// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "ModelHub",
  platforms: [.iOS(.v17)],
  products: [
    .library(name: "ModelHub", targets: ["ModelHub"])
  ],
  dependencies: [
    .package(name: "LanguageModelCore", path: "../LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../LanguageModelRuntime"),
  ],
  targets: [
    .target(
      name: "ModelHub",
      dependencies: [
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "ModelHubTests",
      dependencies: ["ModelHub"],
      swiftSettings: strict
    ),
  ],
  swiftLanguageModes: [.v6]
)
