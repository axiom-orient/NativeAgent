// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKFoundationModels",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "ASKFoundationModels", targets: ["ASKFoundationModels"]),
    ],
    dependencies: [
        .package(name: "ASK", path: "../.."),
    ],
    targets: [
        .target(
            name: "ASKFoundationModels",
            dependencies: [
                .product(name: "ASK", package: "ASK"),
            ]
        ),
        .testTarget(
            name: "ASKFoundationModelsTests",
            dependencies: [
                "ASKFoundationModels",
                .product(name: "ASK", package: "ASK"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
