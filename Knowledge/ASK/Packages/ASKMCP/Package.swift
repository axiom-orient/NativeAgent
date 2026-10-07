// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKMCP",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "ASKMCP", targets: ["ASKMCP"]),
        .executable(name: "ask-mcp", targets: ["askmcpserver"]),
        .executable(name: "ask-mcp-http", targets: ["askmcphttpserver"]),
    ],
    dependencies: [
        .package(name: "ASK", path: "../.."),
        // Retained for ASK-style contract assertions in ASKMCPTests; production
        // targets consume these domain contracts through the ASK package.
        .package(name: "KnowledgeCore", path: "../KnowledgeCore"),
        .package(
            url: "https://github.com/axiom-orient/swiftMcp.git",
            exact: "0.4.2"
        ),
    ],
    targets: [
        .target(
            name: "ASKMCP",
            dependencies: [
                .product(name: "ASK", package: "ASK"),
                .product(name: "MCP", package: "swiftmcp"),
            ]
        ),
        .executableTarget(
            name: "askmcpserver",
            dependencies: [
                "ASKMCP",
                .product(name: "MCPStdioServer", package: "swiftmcp"),
            ]
        ),
        .target(
            name: "ASKMCPHTTP",
            dependencies: [
                "ASKMCP",
                .product(name: "MCP", package: "swiftmcp"),
                .product(name: "MCPHTTPServer", package: "swiftmcp"),
            ]
        ),
        .executableTarget(
            name: "askmcphttpserver",
            dependencies: [
                "ASKMCPHTTP"
            ]
        ),
        .testTarget(
            name: "ASKMCPTests",
            dependencies: [
                "ASKMCP",
                "ASKMCPHTTP",
                .product(name: "MCP", package: "swiftmcp"),
                .product(name: "MCPHTTPClient", package: "swiftmcp"),
                .product(name: "ASK", package: "ASK"),
                .product(name: "KnowledgeCore", package: "KnowledgeCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
