// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKScenarioConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/KnowledgeCore"),
        .package(path: "../../Packages/KnowledgeRuntime"),
        .package(path: "../../Packages/PageIndex"),
    ],
    targets: [
        .executableTarget(
            name: "ScenarioConsumer",
            dependencies: [
                "KnowledgeCore",
                .product(name: "DecisionMemory", package: "KnowledgeRuntime"),
                "PageIndex",
            ]
        )
    ]
)
