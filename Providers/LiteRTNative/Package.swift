// swift-tools-version: 6.2
import PackageDescription

// Sole source-package owner of the official native binary identity. The root
// flattened manifest mirrors this declaration and is checked by qualification.
let version = "0.18.0"
var products: [Product] = [.library(name: "LiteRTNative", targets: ["LiteRTNative"])]
var targets: [Target] = [.target(name: "LiteRTNative")]
#if os(macOS)
products += [
  .library(name: "CLiteRTLM", targets: ["CLiteRTLM"]),
  .library(name: "CLiteRTLM_mac", targets: ["CLiteRTLM_mac"]),
]
targets += [
  .binaryTarget(name: "CLiteRTLM",
    url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v\(version)/CLiteRTLM.xcframework.zip",
    checksum: "d765b99592d4ec3d0c9e2bd69469454af06c834861340672da1891c0c121c347"),
  .binaryTarget(name: "CLiteRTLM_mac",
    url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v\(version)/CLiteRTLM_mac.xcframework.zip",
    checksum: "5f6ee68d95eeccb084c6e66d5ee47255e3020fa0fb29696dd0301ae26d6cfb4f"),
]
#endif
let package = Package(
  name: "LiteRTNative",
  platforms: [.iOS(.v17), .macOS(.v15)],
  products: products, targets: targets, swiftLanguageModes: [.v6]
)
