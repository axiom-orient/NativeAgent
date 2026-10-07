// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "EmbeddingCore",
  platforms: [.iOS(.v17), .macOS(.v15)],
  products: [.library(name: "EmbeddingCore", targets: ["EmbeddingCore"])],
  targets: [
    .target(name: "EmbeddingCore"),
    .testTarget(name: "EmbeddingCoreTests", dependencies: ["EmbeddingCore"]),
  ],
  swiftLanguageModes: [.v6]
)
