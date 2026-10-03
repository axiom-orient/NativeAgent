// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WorkWiki",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "WorkWiki", targets: ["WorkWiki"])],
    dependencies: [
        .package(path: "../KnowledgeCore"),
        .package(path: "../KnowledgeRuntime"),
        .package(path: "../EvidenceIndex"),
        .package(path: "../PageIndex"),
    ],
    targets: [
        .target(
            name: "WorkWiki",
            dependencies: [
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "DecisionMemory", package: "KnowledgeRuntime"),
                .product(name: "EvidenceIndex", package: "EvidenceIndex"),
                .product(name: "PageIndex", package: "PageIndex"),
            ]
        ),
        .testTarget(
            name: "WorkWikiTests",
            dependencies: [
                "WorkWiki",
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "DecisionMemory", package: "KnowledgeRuntime"),
                .product(name: "EvidenceIndex", package: "EvidenceIndex"),
                .product(name: "PageIndex", package: "PageIndex"),
            ],
            resources: [.process("ASKWorkWikiBenchmarkTests/Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
