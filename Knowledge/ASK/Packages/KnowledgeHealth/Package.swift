// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KnowledgeHealth",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "KnowledgeHealth", targets: ["KnowledgeHealth"])],
    dependencies: [
        .package(path: "../KnowledgeRuntime"),
        .package(path: "../EvidenceIndex"),
    ],
    targets: [
        .target(
            name: "KnowledgeHealth",
            dependencies: [
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "EvidenceIndex", package: "EvidenceIndex"),
            ]
        ),
        .testTarget(
            name: "KnowledgeHealthTests",
            dependencies: [
                "KnowledgeHealth",
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "EvidenceIndex", package: "EvidenceIndex"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
