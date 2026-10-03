// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKDeepConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/ASKApplication"),
        .package(path: "../../Packages/DocumentCore"),
        .package(path: "../../Packages/DocumentRuntime"),
        .package(path: "../../Packages/DocumentUI"),
        .package(path: "../../Packages/EvidenceIndex"),
        .package(path: "../../Packages/HTMLDocument"),
        .package(path: "../../Packages/HWPDocument"),
        .package(path: "../../Packages/KnowledgeCore"),
        .package(path: "../../Packages/KnowledgeHealth"),
        .package(path: "../../Packages/KnowledgePresentation"),
        .package(path: "../../Packages/KnowledgeRuntime"),
        .package(path: "../../Packages/MarkdownWiki"),
        .package(path: "../../Packages/PageIndex"),
        .package(path: "../../Packages/SourceCapture"),
        .package(path: "../../Packages/ASKTutor"),
        .package(path: "../../Packages/WorkWiki"),
    ],
    targets: [
        .executableTarget(
            name: "DeepConsumer",
            dependencies: [
                "ASKApplication", "DocumentCore", "DocumentRuntime", "DocumentUI",
                "EvidenceIndex", "HTMLDocument", "HWPDocument", "KnowledgeCore",
                "KnowledgeHealth", "KnowledgePresentation", "KnowledgeRuntime",
                "MarkdownWiki", "PageIndex", "SourceCapture", "ASKTutor", "WorkWiki",
            ]
        )
    ]
)
