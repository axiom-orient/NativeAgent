// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures"),
]
let package = Package(
  name: "NativeLanguageModels", platforms: [.iOS(.v17), .macOS(.v15)],
  products: [.library(name: "NativeLanguageModels", targets: ["NativeLanguageModels"])],
  dependencies: [
    .package(path: "../LanguageModelCore"), .package(path: "../LanguageModelRuntime"),
  ],
  targets: [
    .target(
      name: "NativeLanguageModels",
      dependencies: [
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
      ], swiftSettings: strict),
    .testTarget(
      name: "NativeLanguageModelsTests",
      dependencies: [
        "NativeLanguageModels",
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
      ], swiftSettings: strict),
  ], swiftLanguageModes: [.v6])
