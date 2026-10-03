// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ResponsePolicyQualification",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(name: "NativeAgentPackage", path: "../../Agent/NativeAgentPackage"),
    .package(name: "AppleSystemModelProvider", path: "../../Providers/AppleSystemModel"),
  ],
  targets: [
    .executableTarget(
      name: "DurableLiveQualification",
      dependencies: [
        .product(name: "NativeAgent", package: "NativeAgentPackage"),
        .product(name: "NativeAgentManager", package: "NativeAgentPackage"),
        .product(name: "AppleSystemModelProvider", package: "AppleSystemModelProvider"),
      ]
    ),
    .executableTarget(
      name: "ResponsePolicyQualification",
      dependencies: [
        .product(name: "NativeAgent", package: "NativeAgentPackage"),
        .product(name: "NativeAgentManager", package: "NativeAgentPackage"),
        .product(name: "AppleSystemModelProvider", package: "AppleSystemModelProvider"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
