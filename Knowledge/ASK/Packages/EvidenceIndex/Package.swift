// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EvidenceIndex",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "EvidenceIndex", targets: ["EvidenceIndex"])],
    dependencies: [.package(path: "../PageIndex")],
    targets: [
        .target(
            name: "EvidenceIndex",
            dependencies: [.product(name: "PageIndex", package: "PageIndex")]
        ),
        .testTarget(
            name: "EvidenceIndexTests",
            dependencies: ["EvidenceIndex", .product(name: "PageIndex", package: "PageIndex")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
