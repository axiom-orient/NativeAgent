// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SourceCapture",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "SourceCapture", targets: ["SourceCapture"])],
    dependencies: [
        .package(path: "../KnowledgeCore"),
        .package(path: "../KnowledgeRuntime"),
        .package(path: "../HTMLDocument"),
    ],
    targets: [
        .target(
            name: "SourceCapture",
            dependencies: [
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
                .product(name: "HTMLDocument", package: "HTMLDocument"),
            ]
        ),
        .testTarget(
            name: "SourceCaptureTests",
            dependencies: [
                "SourceCapture",
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
                .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
            ],
            exclude: ["ASKWebCoreTests/Resources"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
