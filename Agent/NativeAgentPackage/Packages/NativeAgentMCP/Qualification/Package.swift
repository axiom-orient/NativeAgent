// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MCPRealPeer", platforms: [.macOS(.v15)], dependencies: [
.package(path: ".."),
.package(path: "../../.."),
.package(url: "https://github.com/axiom-orient/swiftMcp.git", exact: "0.4.2")], targets: [
.executableTarget(name: "Peer", dependencies: [.product(name: "MCP", package: "swiftMcp"), .product(name: "MCPStdioServer", package: "swiftMcp")]),
.executableTarget(name: "AuthProbe", dependencies: [.product(name: "NativeAgentMCP", package: "NativeAgentMCP"), .product(name: "MCP", package: "swiftMcp"), .product(name: "MCPHTTPClient", package: "swiftMcp")]),
.executableTarget(name: "Probe", dependencies: [.product(name: "NativeAgentMCP", package: "NativeAgentMCP"), .product(name: "NativeAgentDomain", package: "NativeAgentPackage"), .product(name: "MCP", package: "swiftMcp"), .product(name: "MCPStdioClient", package: "swiftMcp")])])
