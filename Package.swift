// swift-tools-version: 6.2
import PackageDescription

// This distribution profile is a local source-graph composition. Its sibling
// package(path:) edges are not consumable from a remote Git dependency yet.
let package = Package(
    name: "NativeAgent",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "NativeAgentSumday", targets: ["NativeAgentSumday"]),
    ],
    dependencies: [
        .package(name: "NativeAgentPackage", path: "Agent/NativeAgentPackage"),
        .package(name: "LanguageModelCorePackage", path: "Model/LanguageModelCore"),
        .package(name: "LanguageModelRuntimePackage", path: "Model/LanguageModelRuntime"),
        .package(name: "ModelArtifactStorePackage", path: "Model/ModelArtifactStore"),
        .package(name: "LEAPProviderPackage", path: "Providers/LEAP"),
        .package(name: "ChatGPTAccountPackage", path: "Providers/ChatGPT/Account"),
        .package(name: "ChatGPTTextPackage", path: "Providers/ChatGPT/Text"),
        .package(name: "ChatGPTImagePackage", path: "Providers/ChatGPT/Image"),
        .package(
            name: "ChatGPTImageCapabilityPackage",
            path: "Agent/NativeAgentPackage/Packages/ChatGPTImageCapability"
        ),
        .package(name: "ASKPackage", path: "Knowledge/ASK"),
        .package(name: "NativeAgentUIPackage", path: "UI"),
    ],
    targets: [
        .target(
            name: "NativeAgentSumday",
            dependencies: [
                .product(name: "NativeAgent", package: "NativeAgentPackage"),
                .product(name: "NativeAgentDomain", package: "NativeAgentPackage"),
                .product(name: "NativeAgentManager", package: "NativeAgentPackage"),
                .product(name: "LanguageModelCore", package: "LanguageModelCorePackage"),
                .product(name: "LanguageModelRuntime", package: "LanguageModelRuntimePackage"),
                .product(name: "ModelArtifactStore", package: "ModelArtifactStorePackage"),
                .product(name: "LEAPProvider", package: "LEAPProviderPackage"),
                .product(name: "ChatGPTAccount", package: "ChatGPTAccountPackage"),
                .product(name: "ChatGPTText", package: "ChatGPTTextPackage"),
                .product(name: "ChatGPTImage", package: "ChatGPTImagePackage"),
                .product(
                    name: "ChatGPTImageCapability",
                    package: "ChatGPTImageCapabilityPackage"
                ),
                .product(name: "ASK", package: "ASKPackage"),
                .product(name: "NativeAgentUI", package: "NativeAgentUIPackage"),
                .product(name: "NativeAgentPresentation", package: "NativeAgentUIPackage"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
