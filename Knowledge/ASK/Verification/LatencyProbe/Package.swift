// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKLatencyProbe",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "ASKLatencyProbe", targets: ["ASKLatencyProbe"]),
        .executable(name: "LatencyProbe", targets: ["LatencyProbeCLI"]),
    ],
    dependencies: [
        .package(name: "ASK", path: "../.."),
        .package(name: "KnowledgeCore", path: "../../Packages/KnowledgeCore"),
    ],
    targets: [
        .target(
            name: "ASKLatencyProbe",
            dependencies: [
                .product(name: "ASK", package: "ASK"),
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
            ]
        ),
        .executableTarget(
            name: "LatencyProbeCLI",
            dependencies: ["ASKLatencyProbe"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
