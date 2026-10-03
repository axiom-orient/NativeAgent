// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HTMLDocument",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "HTMLDocument", targets: ["HTMLDocument"])],
    targets: [
        .target(name: "HTMLDocument"),
        .testTarget(name: "HTMLDocumentTests", dependencies: ["HTMLDocument"]),
    ],
    swiftLanguageModes: [.v6]
)
