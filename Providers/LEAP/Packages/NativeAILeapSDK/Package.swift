// swift-tools-version: 6.2
import PackageDescription

// One upstream binary identity shared by the two frontend packages.
// No installation, residency, inference or cancellation authority lives here.
let package = Package(
  name: "NativeAILeapSDK",
  platforms: [.iOS(.v17)],
  products: [.library(name: "LeapSDK", targets: ["LeapSDK"])],
  targets: [
    .binaryTarget(
      name: "LeapSDK",
      url: "https://github.com/Liquid4All/leap-sdk/releases/download/v0.10.13-SNAPSHOT/LeapSDK.xcframework.zip",
      checksum: "99abbed6967de43dfa2b3ad03350f4146bf9ab9194a2fbc719d239066e6becc3"
    )
  ]
)
