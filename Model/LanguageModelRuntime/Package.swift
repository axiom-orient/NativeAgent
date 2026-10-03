// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures"),
]
let package = Package(
  name: "LanguageModelRuntime",
  platforms: [.iOS(.v17)],
  products: [.library(name: "LanguageModelRuntime", targets: ["LanguageModelRuntime"])],
  dependencies: [.package(name: "LanguageModelCore", path: "../LanguageModelCore")],
  targets: [
    .target(
      name: "LanguageModelRuntime",
      dependencies: [.product(name: "LanguageModelCore", package: "LanguageModelCore")],
      swiftSettings: strict),
    .testTarget(
      name: "LanguageModelRuntimeTests",
      dependencies: [
        "LanguageModelRuntime", .product(name: "LanguageModelCore", package: "LanguageModelCore"),
      ], swiftSettings: strict),
  ],
  swiftLanguageModes: [.v6]
)
