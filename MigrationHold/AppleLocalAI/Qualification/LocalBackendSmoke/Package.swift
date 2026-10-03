// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "LocalBackendSmoke",
  platforms: [.macOS("27.0")],
  products: [.executable(name: "LocalBackendSmoke", targets: ["LocalBackendSmoke"])],
  dependencies: [
    .package(name: "NativeAgentPackage", path: "../../../../Agent/NativeAgentPackage"),
    .package(path: "../../../../Model/LanguageModelRuntime"),
    .package(name: "LiteRTProvider", path: "../../../../Providers/LiteRT"),
    .package(path: "../.."),
    .package(path: "../../Packages/NativeAgentProviderAppleLocalAI"),
  ],
  targets: [
    .executableTarget(
      name: "LocalBackendSmoke",
      dependencies: [
        .product(name: "NativeAgent", package: "NativeAgentPackage"),
        .product(name: "NativeAgentManager", package: "NativeAgentPackage"),
        .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime"),
        .product(name: "LiteRTProvider", package: "LiteRTProvider"),
        .product(name: "AppleLocalAI", package: "AppleLocalAI"),
        .product(
          name: "NativeAgentProviderAppleLocalAI", package: "NativeAgentProviderAppleLocalAI"),
      ])
  ], swiftLanguageModes: [.v6]
)
