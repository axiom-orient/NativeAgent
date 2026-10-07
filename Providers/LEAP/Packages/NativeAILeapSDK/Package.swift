// swift-tools-version: 6.2
import PackageDescription

// One upstream binary identity for the native provider.
// No installation, residency, inference or cancellation authority lives here.
let package = Package(
  name: "NativeAILeapSDK",
  platforms: [.iOS("26.5"), .macOS(.v26)],
  products: [.library(name: "LeapSDK", targets: ["LeapSDK", "inference_engine"])],
  targets: [
    .binaryTarget(
      name: "LeapSDK",
      url: "https://github.com/Liquid4All/leap-sdk/releases/download/v0.11.0-SNAPSHOT/LeapSDK.xcframework.zip",
      checksum: "f837346f81c73ac9f72e5cb115a9b4087a9155ae743cdc365b702361414343ac"
    ),
    .binaryTarget(
      name: "inference_engine",
      url: "https://github.com/Liquid4All/leap-sdk/releases/download/v0.11.0-SNAPSHOT/inference_engine.xcframework.zip",
      checksum: "bd8f4ca176afc87713f48d49e24301090882e8a10761b476ebcf8ee2cced2ba2"
    )
  ]
)
