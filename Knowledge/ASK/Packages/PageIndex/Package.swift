// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PageIndex",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "PageIndex", targets: ["PageIndex"])],
    dependencies: [
        .package(path: "../KnowledgeCore"),
        .package(path: "../DocumentCore"),
    ],
    targets: [
        .target(
            name: "PageIndex",
            dependencies: [
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
                .product(name: "MarkdownSyntax", package: "DocumentCore"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PageIndexTests",
            dependencies: ["PageIndex"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
