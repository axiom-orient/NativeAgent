// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKProductionCorpusConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../../Packages/KnowledgeCore"),
        .package(path: "../../Packages/KnowledgeRuntime"),
    ],
    targets: [
        .executableTarget(
            name: "ProductionCorpusConsumer",
            dependencies: [.product(name: "ASK", package: "ASK"), "KnowledgeCore", "KnowledgeRuntime"]
        )
    ]
)
