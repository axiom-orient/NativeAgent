// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures"),
]
let package = Package(
  name: "AppleSystemModelProvider",
  platforms: [.iOS(.v17), .macOS(.v26)],
  products: [
    .library(name: "AppleSystemModelProvider", targets: ["AppleSystemModelProvider"])
  ],
  dependencies: [
    .package(name: "LanguageModelCore", path: "../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../Model/LanguageModelRuntime"),
  ],
  targets: [
    .target(
      name: "AppleSystemModelProvider",
      dependencies: [
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
      ], swiftSettings: strict),
    .testTarget(
      name: "AppleSystemModelProviderTests",
      dependencies: [
        "AppleSystemModelProvider",
        .product(name: "LanguageModelCore", package: "LanguageModelCore"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
      ], swiftSettings: strict),
  ],
  swiftLanguageModes: [.v6]
)
