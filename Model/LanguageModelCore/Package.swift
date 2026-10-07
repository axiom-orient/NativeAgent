// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures"),
]
let package = Package(
  name: "LanguageModelCore",
  platforms: [.iOS(.v17), .macOS(.v13)],
  products: [.library(name: "LanguageModelCore", targets: ["LanguageModelCore"])],
  targets: [
    .target(name: "LanguageModelCore", swiftSettings: strict),
    .testTarget(
      name: "LanguageModelCoreTests", dependencies: ["LanguageModelCore"], swiftSettings: strict),
  ],
  swiftLanguageModes: [.v6]
)
