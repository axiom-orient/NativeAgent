// swift-tools-version: 6.2
import PackageDescription

// Optional rendering and immutable view inputs; no runtime, provider or knowledge dependencies.
let package = Package(
    name: "NativeAgentUI",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "NativeAgentUI", targets: ["NativeAgentUI"]),
        .library(name: "NativeAgentPresentation", targets: ["NativeAgentPresentation"]),
    ],
    targets: [
        .target(name: "NativeAgentPresentation"),
        .target(name: "NativeAgentUI", dependencies: ["NativeAgentPresentation"]),
        .testTarget(name: "NativeAgentPresentationTests", dependencies: ["NativeAgentPresentation"]),
    ],
    swiftLanguageModes: [.v6]
)
