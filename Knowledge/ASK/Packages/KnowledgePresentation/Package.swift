// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KnowledgePresentation",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "KnowledgePresentation", targets: ["KnowledgePresentation"])],
    dependencies: [
        .package(path: "../KnowledgeCore"),
        .package(path: "../KnowledgeRuntime"),
        .package(path: "../DocumentCore"),
        .package(path: "../DocumentRuntime"),
        .package(path: "../PageIndex"),
    ],
    targets: [
        .target(
            name: "KnowledgePresentation",
            dependencies: [
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "DocumentCore", package: "DocumentCore"),
                .product(name: "DocumentRuntime", package: "DocumentRuntime"),
                .product(name: "PageIndex", package: "PageIndex"),
            ]
        ),
        .testTarget(
            name: "KnowledgePresentationTests",
            dependencies: [
                "KnowledgePresentation",
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "DocumentCore", package: "DocumentCore"),
                .product(name: "DocumentRuntime", package: "DocumentRuntime"),
                .product(name: "PageIndex", package: "PageIndex"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
