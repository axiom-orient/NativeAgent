// swift-tools-version: 6.4
import PackageDescription
let package = Package(
  name: "AppleLocalAILEAP",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [.library(name: "AppleLocalAILEAP", targets: ["AppleLocalAILEAP"])],
  dependencies: [
    .package(name: "NativeAILeapSDK", path: "../../../../Providers/LEAP/Packages/NativeAILeapSDK")
  ],
  targets: [
    .target(name: "AppleLocalAILEAP", dependencies: [.product(name: "LeapSDK", package: "NativeAILeapSDK")]),

    .testTarget(name: "AppleLocalAILEAPTests", dependencies: ["AppleLocalAILEAP"]),
  ],
  swiftLanguageModes: [.v6]
)
