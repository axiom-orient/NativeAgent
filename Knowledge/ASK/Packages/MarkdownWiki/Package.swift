// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MarkdownWiki",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "MarkdownWiki", targets: ["MarkdownWiki"])],
    targets: [
        .target(name: "MarkdownWiki"),
        .testTarget(name: "MarkdownWikiTests", dependencies: ["MarkdownWiki"]),
    ],
    swiftLanguageModes: [.v6]
)
