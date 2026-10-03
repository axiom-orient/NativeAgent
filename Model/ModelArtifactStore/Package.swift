// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures"),
]
let package = Package(
  name: "ModelArtifactStore",
  platforms: [.iOS(.v17)],
  products: [.library(name: "ModelArtifactStore", targets: ["ModelArtifactStore"])],
  targets: [
    .target(name: "ModelArtifactStore", swiftSettings: strict),
    .executableTarget(
      name: "ModelArtifactStoreTestHelper", dependencies: ["ModelArtifactStore"], swiftSettings: strict),
    .testTarget(
      name: "ModelArtifactStoreTests",
      dependencies: ["ModelArtifactStore", "ModelArtifactStoreTestHelper"], swiftSettings: strict),
  ],
  swiftLanguageModes: [.v6]
)
