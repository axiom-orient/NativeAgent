// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKTutor",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "ASKTutor", targets: ["ASKTutor"])],
    dependencies: [
        .package(name: "ASK", path: "../.."),
        .package(path: "../KnowledgeCore"),
        .package(path: "../KnowledgeRuntime"),
        .package(path: "../EvidenceIndex"),
        .package(path: "../PageIndex"),
        .package(path: "../DocumentCore"),
        .package(path: "../DocumentRuntime"),
        .package(path: "../KnowledgePresentation"),
    ],
    targets: [
        .target(
            name: "ASKTutor",
            dependencies: [
                .product(name: "ASK", package: "ASK"),
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "EvidenceIndex", package: "EvidenceIndex"),
                .product(name: "PageIndex", package: "PageIndex"),
                .product(name: "DocumentCore", package: "DocumentCore"),
                .product(name: "DocumentRuntime", package: "DocumentRuntime"),
                .product(name: "KnowledgePresentation", package: "KnowledgePresentation"),
            ]
        ),
        .testTarget(
            name: "ASKTutorTests",
            dependencies: [
                "ASKTutor",
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "EvidenceIndex", package: "EvidenceIndex"),
                .product(name: "DocumentCore", package: "DocumentCore"),
                .product(name: "DocumentRuntime", package: "DocumentRuntime"),
                .product(name: "KnowledgePresentation", package: "KnowledgePresentation"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
