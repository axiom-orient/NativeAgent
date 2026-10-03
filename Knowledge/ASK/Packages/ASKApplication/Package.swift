// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKApplication",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "ASKApplication", targets: ["ASKApplication"]),
    ],
    dependencies: [
        .package(path: "../KnowledgeRuntime"),
        .package(path: "../KnowledgeHealth"),
        .package(path: "../EvidenceIndex"),
        .package(path: "../WorkWiki"),
    ],
    targets: [
        .target(
            name: "ASKApplication",
            dependencies: [
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "KnowledgeHealth", package: "KnowledgeHealth"),
                .product(name: "EvidenceIndex", package: "EvidenceIndex"),
                .product(name: "WorkWiki", package: "WorkWiki"),
            ]
        ),
        .testTarget(
            name: "ASKApplicationTests",
            dependencies: [
                "ASKApplication",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
