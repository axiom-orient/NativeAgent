// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KnowledgeCore",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "KnowledgeCore", targets: ["KnowledgeCore"])],
    targets: [
        .target(name: "KnowledgeCore"),
        .testTarget(
            name: "KnowledgeCoreTests",
            dependencies: ["KnowledgeCore"],
            exclude: ["ASKCoreTests/Resources"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
