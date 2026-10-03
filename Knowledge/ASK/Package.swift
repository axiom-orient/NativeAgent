// swift-tools-version: 6.2
import PackageDescription

let products: [Product] = [
    .library(name: "ASK", targets: ["ASK"]),
]

let dependencies: [Package.Dependency] = [
    .package(path: "Packages/ASKApplication"),
    .package(path: "Packages/KnowledgeCore"),
    .package(path: "Packages/KnowledgeRuntime"),
    .package(path: "Packages/KnowledgeHealth"),
    .package(path: "Packages/EvidenceIndex"),
    .package(path: "Packages/PageIndex"),
    .package(path: "Packages/DocumentCore"),
    .package(path: "Packages/WorkWiki"),
    .package(path: "Packages/KnowledgePresentation"),
]

let targets: [Target] = [
    .target(
        name: "ASK",
        dependencies: [
            .product(name: "ASKApplication", package: "ASKApplication"),
            .product(name: "KnowledgeCore", package: "KnowledgeCore"),
            .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"),
            .product(name: "KnowledgeHealth", package: "KnowledgeHealth"),
            .product(name: "EvidenceIndex", package: "EvidenceIndex"),
            .product(name: "PageIndex", package: "PageIndex"),
            .product(name: "DocumentCore", package: "DocumentCore"),
            .product(name: "WorkWiki", package: "WorkWiki"),
            .product(name: "KnowledgePresentation", package: "KnowledgePresentation"),
        ]
    ),
    .testTarget(name: "ASKTests", dependencies: ["ASK"]),
]


let package = Package(
    name: "ASK",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)
