// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures"),
]
let package = Package(
  name: "FoundationModelsBridge",
  platforms: [.iOS("27.0"), .macOS("27.0"), .visionOS("27.0")],
  products: [.library(name: "FoundationModelsBridge", targets: ["FoundationModelsBridge"])],
  dependencies: [.package(path: "../LanguageModelCore")],
  targets: [
    .target(
      name: "FoundationModelsBridge",
      dependencies: [
        .product(name: "LanguageModelCore", package: "LanguageModelCore")
      ], swiftSettings: strict),
    .testTarget(
      name: "FoundationModelsBridgeTests",
      dependencies: [
        "FoundationModelsBridge",
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
      ], swiftSettings: strict),
  ], swiftLanguageModes: [.v6])
