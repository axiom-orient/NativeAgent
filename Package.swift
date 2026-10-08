// swift-tools-version: 6.3
import PackageDescription

var liteRTNativeTargets: [Target] = []
var liteRTBinaryDependencies: [Target.Dependency] = []
#if os(macOS)
liteRTNativeTargets = [
    .binaryTarget(name: "CLiteRTLM", url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.0/CLiteRTLM.xcframework.zip", checksum: "d765b99592d4ec3d0c9e2bd69469454af06c834861340672da1891c0c121c347"),
    .binaryTarget(name: "CLiteRTLM_mac", url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.0/CLiteRTLM_mac.xcframework.zip", checksum: "5f6ee68d95eeccb084c6e66d5ee47255e3020fa0fb29696dd0301ae26d6cfb4f"),
]
liteRTBinaryDependencies = [
    .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
    .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS])),
]
#endif

// Flattened remote distribution graph. Independent subpackage manifests remain
// for local development; the Git package root has no local package dependencies.
let package = Package(
    name: "NativeAgent",
    platforms: [.iOS("26.5"), .macOS(.v26)],
    products: [
        .library(name: "NativeAgent", targets: ["NativeAgent"]),
        .library(name: "NativeAgentDomain", targets: ["NativeAgentDomain"]),
        .library(name: "NativeAgentManager", targets: ["NativeAgentManager"]),
        .library(name: "LanguageModelCore", targets: ["LanguageModelCore"]),
        .library(name: "LanguageModelRuntime", targets: ["LanguageModelRuntime"]),
        .library(name: "ModelArtifactStore", targets: ["ModelArtifactStore"]),
        .library(name: "EmbeddingCore", targets: ["EmbeddingCore"]),
        .library(name: "LiteRTEmbeddingProvider", targets: ["LiteRTEmbeddingProvider"]),
        .library(name: "LiteRTProvider", targets: ["LiteRTProvider"]),
        .library(name: "LEAPProvider", targets: ["LEAPProvider"]),
        .library(name: "MLXProvider", targets: ["MLXProvider"]),
        .library(name: "MLXModelRegistry", targets: ["MLXModelRegistry"]),
        .library(name: "ChatGPTAccount", targets: ["ChatGPTAccount"]),
        .library(name: "ChatGPTText", targets: ["ChatGPTText"]),
        .library(name: "ChatGPTTextProvider", targets: ["ChatGPTTextProvider"]),
        .library(name: "ChatGPTImage", targets: ["ChatGPTImage"]),
        .library(name: "ChatGPTImageCapability", targets: ["ChatGPTImageCapability"]),
        .library(name: "AppleSystemModelProvider", targets: ["AppleSystemModelProvider"]),
        .library(name: "ASK", targets: ["ASK"]),
        .library(name: "NativeAgentUI", targets: ["NativeAgentUI"]),
        .library(name: "NativeAgentPresentation", targets: ["NativeAgentPresentation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.13.0", traits: []),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        .target(
            name: "MLXModelRegistry",
            dependencies: [
                .target(name: "ModelArtifactStore"),
                .target(name: "ModelHub"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Providers/MLX/Sources/MLXModelRegistry",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "MLXProvider",
            dependencies: [
                .target(name: "LanguageModelCore"),
                .target(name: "LanguageModelRuntime"),
                .target(name: "ModelArtifactStore"),
                .target(name: "ModelHub"),
                .target(name: "MLXModelRegistry"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Providers/MLX/Sources/MLXProvider",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(name: "EmbeddingCore", path: "Model/EmbeddingCore/Sources/EmbeddingCore"),
        .target(name: "LiteRTNative", path: "Providers/LiteRTNative/Sources/LiteRTNative"),
        .target(name: "LiteRTEmbeddingProvider", dependencies: [.target(name: "EmbeddingCore"), .target(name: "LiteRTNative"), .target(name: "ModelArtifactStore"), .product(name: "HuggingFace", package: "swift-huggingface")] + liteRTBinaryDependencies,
                path: "Providers/LiteRTEmbedding/Sources/LiteRTEmbeddingProvider"),
        .target(name: "LiteRTProvider", dependencies: [
                .target(name: "LanguageModelCore"), .target(name: "LanguageModelRuntime"),
                .target(name: "ModelArtifactStore"), .target(name: "ModelHub"), .target(name: "LiteRTNative"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ] + liteRTBinaryDependencies, path: "Providers/LiteRT/Sources/LiteRTProvider",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]),
        .target(
            name: "ASK",
            dependencies: [
                .target(name: "ASKApplication"),
                .target(name: "KnowledgeCore"),
                .target(name: "KnowledgeRuntime"),
                .target(name: "KnowledgeHealth"),
                .target(name: "EvidenceIndex"),
                .target(name: "PageIndex"),
                .target(name: "DocumentCore"),
                .target(name: "WorkWiki"),
                .target(name: "KnowledgePresentation")
            ],
            path: "Knowledge/ASK/Sources/ASK"
        ),
        .target(
            name: "ASKApplication",
            dependencies: [
                .target(name: "KnowledgeRuntime"),
                .target(name: "KnowledgeHealth"),
                .target(name: "EvidenceIndex"),
                .target(name: "WorkWiki")
            ],
            path: "Knowledge/ASK/Packages/ASKApplication/Sources/ASKApplication"
        ),
        .systemLibrary(name: "ASKCSQLite", path: "Knowledge/ASK/Packages/KnowledgeRuntime/Sources/CSQLite"),
        // A concrete C build node survives Xcode's hosted-test dynamic-product
        // promotion. The module and platform SQLite implementation stay unchanged.
        .target(name: "CSQLite", path: "Agent/NativeAgentPackage/Sources/CSQLite",
                publicHeadersPath: ".", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(
            name: "ChatGPTAccount",
            path: "Providers/ChatGPT/Account/Sources/ChatGPTAccount",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "ChatGPTImage",
            dependencies: [
                .target(name: "ChatGPTAccount")
            ],
            path: "Providers/ChatGPT/Image/Sources/ChatGPTImage",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "ChatGPTTextProvider",
            dependencies: ["ChatGPTAccount", "ChatGPTText", "LanguageModelCore", "LanguageModelRuntime"],
            path: "Providers/ChatGPT/TextProvider/Sources/ChatGPTTextProvider",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "AppleSystemModelProvider",
            dependencies: ["LanguageModelCore", "LanguageModelRuntime"],
            path: "Providers/AppleSystemModel/Sources/AppleSystemModelProvider",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "ChatGPTImageCapability",
            dependencies: [
                .target(name: "NativeAgentDomain"),
                .target(name: "NativeAgentSkills"),
                .target(name: "ChatGPTAccount"),
                .target(name: "ChatGPTImage"),
                .target(name: "LanguageModelCore")
            ],
            path: "Agent/NativeAgentPackage/Packages/ChatGPTImageCapability/Sources/ChatGPTImageCapability",
            resources: [.copy("Resources/ImageCatalog")],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "ChatGPTText",
            dependencies: [
                .target(name: "ChatGPTAccount"),
                .target(name: "LanguageModelCore")
            ],
            path: "Providers/ChatGPT/Text/Sources/ChatGPTText",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "DecisionMemory",
            dependencies: [
                .target(name: "KnowledgeRuntime"),
                .target(name: "KnowledgeCore")
            ],
            path: "Knowledge/ASK/Packages/KnowledgeRuntime/Sources/DecisionMemory"
        ),
        .target(
            name: "DocumentCore",
            dependencies: [
                .target(name: "MarkdownSyntax")
            ],
            path: "Knowledge/ASK/Packages/DocumentCore/Sources/DocumentCore"
        ),
        .target(
            name: "DocumentRuntime",
            dependencies: [
                .target(name: "DocumentCore")
            ],
            path: "Knowledge/ASK/Packages/DocumentRuntime/Sources/DocumentRuntime"
        ),
        .target(
            name: "EvidenceIndex",
            dependencies: [
                .target(name: "PageIndex")
            ],
            path: "Knowledge/ASK/Packages/EvidenceIndex/Sources/EvidenceIndex"
        ),
        .target(
            name: "KnowledgeCore",
            path: "Knowledge/ASK/Packages/KnowledgeCore/Sources/KnowledgeCore"
        ),
        .target(
            name: "KnowledgeHealth",
            dependencies: [
                .target(name: "KnowledgeRuntime"),
                .target(name: "EvidenceIndex")
            ],
            path: "Knowledge/ASK/Packages/KnowledgeHealth/Sources/KnowledgeHealth"
        ),
        .target(
            name: "KnowledgePresentation",
            dependencies: [
                .target(name: "KnowledgeRuntime"),
                .target(name: "DocumentCore"),
                .target(name: "DocumentRuntime"),
                .target(name: "PageIndex")
            ],
            path: "Knowledge/ASK/Packages/KnowledgePresentation/Sources/KnowledgePresentation"
        ),
        .target(
            name: "KnowledgeRuntime",
            dependencies: [
                .target(name: "KnowledgeCore"),
                .target(name: "ASKCSQLite")
            ],
            path: "Knowledge/ASK/Packages/KnowledgeRuntime/Sources/KnowledgeRuntime"
        ),
        .target(
            name: "LEAPProvider",
            dependencies: [
                .target(name: "LanguageModelCore"),
                .target(name: "LanguageModelRuntime"),
                .target(name: "ModelArtifactStore"),
                .target(name: "ModelHub"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .target(name: "LeapSDK"),
                .target(name: "inference_engine")
            ],
            path: "Providers/LEAP/Sources/LEAPProvider",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "LanguageModelCore",
            path: "Model/LanguageModelCore/Sources/LanguageModelCore",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "LanguageModelRuntime",
            dependencies: [
                .target(name: "LanguageModelCore")
            ],
            path: "Model/LanguageModelRuntime/Sources/LanguageModelRuntime",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .binaryTarget(name: "inference_engine", url: "https://github.com/Liquid4All/leap-sdk/releases/download/v0.11.0-SNAPSHOT/inference_engine.xcframework.zip", checksum: "bd8f4ca176afc87713f48d49e24301090882e8a10761b476ebcf8ee2cced2ba2"),
        .binaryTarget(name: "LeapSDK", url: "https://github.com/Liquid4All/leap-sdk/releases/download/v0.11.0-SNAPSHOT/LeapSDK.xcframework.zip", checksum: "f837346f81c73ac9f72e5cb115a9b4087a9155ae743cdc365b702361414343ac"),
        .target(
            name: "MarkdownSyntax",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            path: "Knowledge/ASK/Packages/DocumentCore/Sources/MarkdownSyntax"
        ),
        .target(
            name: "ModelArtifactStore",
            path: "Model/ModelArtifactStore/Sources/ModelArtifactStore",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "ModelHub",
            dependencies: [
                .target(name: "LanguageModelCore"),
                .target(name: "LanguageModelRuntime")
            ],
            path: "Model/ModelHub/Sources/ModelHub",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "NativeAgent",
            dependencies: [
                .target(name: "LanguageModelCore"),
                .target(name: "LanguageModelRuntime"),
                .target(name: "NativeAgentDomain"),
                .target(name: "NativeAgentExecution"),
                .target(name: "NativeAgentStore")
            ],
            path: "Agent/NativeAgentPackage/Sources/NativeAgent",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "NativeAgentDomain",
            dependencies: [
                .target(name: "LanguageModelCore")
            ],
            path: "Agent/NativeAgentPackage/Sources/NativeAgentDomain",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "NativeAgentExecution",
            dependencies: [
                .target(name: "NativeAgentDomain"),
                .target(name: "LanguageModelRuntime")
            ],
            path: "Agent/NativeAgentPackage/Sources/NativeAgentExecution",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "NativeAgentManager",
            dependencies: [
                .target(name: "NativeAgent"),
                .target(name: "NativeAgentDomain"),
                .target(name: "NativeAgentSkills"),
                .target(name: "LanguageModelCore"),
                .target(name: "LanguageModelRuntime")
            ],
            path: "Agent/NativeAgentPackage/Sources/NativeAgentManager",
            resources: [.copy("ResponsePolicies")],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "NativeAgentPresentation",
            path: "UI/Sources/NativeAgentPresentation"
        ),
        .target(
            name: "NativeAgentSkills",
            dependencies: [
                .target(name: "NativeAgentDomain"),
                .target(name: "LanguageModelCore")
            ],
            path: "Agent/NativeAgentPackage/Sources/NativeAgentSkills",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "NativeAgentStore",
            dependencies: [
                .target(name: "NativeAgentDomain"),
                .target(name: "CSQLite")
            ],
            path: "Agent/NativeAgentPackage/Sources/NativeAgentStore",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"), .enableUpcomingFeature("ImmutableWeakCaptures")]
        ),
        .target(
            name: "NativeAgentUI",
            dependencies: [
                .target(name: "NativeAgentPresentation")
            ],
            path: "UI/Sources/NativeAgentUI"
        ),
        .target(
            name: "PageIndex",
            dependencies: [
                .target(name: "KnowledgeCore"),
                .target(name: "MarkdownSyntax")
            ],
            path: "Knowledge/ASK/Packages/PageIndex/Sources/PageIndex",
            resources: [.process("Resources")]
        ),
        .target(
            name: "WorkWiki",
            dependencies: [
                .target(name: "KnowledgeCore"),
                .target(name: "KnowledgeRuntime"),
                .target(name: "DecisionMemory"),
                .target(name: "EvidenceIndex"),
                .target(name: "PageIndex")
            ],
            path: "Knowledge/ASK/Packages/WorkWiki/Sources/WorkWiki"
        ),
    ] + liteRTNativeTargets,
    swiftLanguageModes: [.v6]
 )
