// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "ASKAgentTools", platforms: [.iOS(.v17), .macOS(.v15)],
  products: [.library(name: "ASKAgentTools", targets: ["ASKAgentTools"])],
  dependencies: [
    .package(path: "../.."),
    .package(name: "NativeAgentPackage", path: "../../../../Agent/NativeAgentPackage"),
    .package(path: "../../../../Model/LanguageModelCore"),
  ],
  targets: [
    .target(
      name: "ASKAgentTools",
      dependencies: [
        .product(name: "ASK", package: "ASK"),
        .product(name: "NativeAgentDomain", package: "NativeAgentPackage"),
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
      ], swiftSettings: strict),
    .testTarget(name: "ASKAgentToolsTests", dependencies: ["ASKAgentTools"], swiftSettings: strict),
  ], swiftLanguageModes: [.v6]
)
