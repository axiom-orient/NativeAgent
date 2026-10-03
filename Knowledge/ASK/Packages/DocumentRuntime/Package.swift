// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DocumentRuntime",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "DocumentRuntime", targets: ["DocumentRuntime"])],
    dependencies: [.package(path: "../DocumentCore")],
    targets: [
        .target(
            name: "DocumentRuntime",
            dependencies: [.product(name: "DocumentCore", package: "DocumentCore")]
        ),
        .testTarget(
            name: "DocumentRuntimeTests",
            dependencies: [
                "DocumentRuntime",
                .product(name: "DocumentCore", package: "DocumentCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
