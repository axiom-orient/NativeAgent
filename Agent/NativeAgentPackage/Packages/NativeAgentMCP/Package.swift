// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "NativeAgentMCP",
  platforms: [.iOS(.v17)],
  products: [.library(name: "NativeAgentMCP", targets: ["NativeAgentMCP"])],
  dependencies: [
    .package(name: "NativeAgentPackage", path: "../.."),
    .package(url: "https://github.com/axiom-orient/swiftMcp.git", exact: "0.4.1"),
  ],
  targets: [
    .target(
      name: "NativeAgentMCP",
      dependencies: [
        .product(name: "NativeAgentDomain", package: "NativeAgentPackage"),
        .product(name: "MCP", package: "swiftmcp"),
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentMCPTests",
      dependencies: [
        "NativeAgentMCP",
        .product(name: "NativeAgentDomain", package: "NativeAgentPackage"),
        .product(name: "MCP", package: "swiftmcp"),
      ],
      swiftSettings: strict
    ),
  ],
  swiftLanguageModes: [.v6]
)
