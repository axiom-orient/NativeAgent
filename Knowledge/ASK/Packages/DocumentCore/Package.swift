// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DocumentCore",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "DocumentCore", targets: ["DocumentCore"]),
        .library(name: "MarkdownSyntax", targets: ["MarkdownSyntax"]),
    ],
    dependencies: [
        // Swift Markdown is backed by cmark-gfm. Pin the parser dialect rather
        // than letting PageIndex's persisted source anchors drift with an
        // unreviewed parser upgrade.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    ],
    targets: [
        .target(
            name: "MarkdownSyntax",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .target(name: "DocumentCore", dependencies: ["MarkdownSyntax"]),
        .testTarget(name: "DocumentCoreTests", dependencies: ["DocumentCore"]),
        .testTarget(name: "MarkdownSyntaxTests", dependencies: ["MarkdownSyntax"]),
    ],
    swiftLanguageModes: [.v6]
)
