// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KnowledgeRuntime",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "KnowledgeRuntime", targets: ["KnowledgeRuntime"]),
        .library(name: "DecisionMemory", targets: ["DecisionMemory"]),
    ],
    dependencies: [
        .package(path: "../KnowledgeCore"),
    ],
    targets: [
        .systemLibrary(name: "ASKCSQLite", path: "Sources/CSQLite"),
        .target(
            name: "KnowledgeRuntime",
            dependencies: [
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
                "ASKCSQLite",
            ]
        ),
        .target(
            name: "DecisionMemory",
            dependencies: [
                "KnowledgeRuntime",
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
            ]
        ),
        .testTarget(
            name: "KnowledgeRuntimeTests",
            dependencies: [
                "KnowledgeRuntime",
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
            ],
            exclude: ["ASKPlanningTests/Resources"]
        ),
        .testTarget(
            name: "DecisionMemoryTests",
            dependencies: [
                "DecisionMemory",
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
