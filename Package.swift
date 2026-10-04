// swift-tools-version: 6.2
import PackageDescription

// Flattened remote distribution graph. Independent subpackage manifests remain
// for local development; the Git package root has no local package dependencies.
let package = Package(
    name: "NativeAgent",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "NativeAgent", targets: ["NativeAgent"]),
        .library(name: "NativeAgentDomain", targets: ["NativeAgentDomain"]),
        .library(name: "NativeAgentManager", targets: ["NativeAgentManager"]),
        .library(name: "LanguageModelCore", targets: ["LanguageModelCore"]),
        .library(name: "LanguageModelRuntime", targets: ["LanguageModelRuntime"]),
        .library(name: "ModelArtifactStore", targets: ["ModelArtifactStore"]),
        .library(name: "LEAPProvider", targets: ["LEAPProvider"]),
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
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.10.2"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    ],
    targets: [
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
        .systemLibrary(name: "CSQLite", path: "Agent/NativeAgentPackage/Sources/CSQLite"),
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
                .target(name: "LeapSDK")
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
        .binaryTarget(name: "LeapSDK", url: "https://github.com/Liquid4All/leap-sdk/releases/download/v0.10.13-SNAPSHOT/LeapSDK.xcframework.zip", checksum: "99abbed6967de43dfa2b3ad03350f4146bf9ab9194a2fbc719d239066e6becc3"),
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
    ],
    swiftLanguageModes: [.v6]
 )
