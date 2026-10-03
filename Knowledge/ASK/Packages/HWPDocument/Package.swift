// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HWPDocument",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "HWPDocument", targets: ["HWPDocument"])],
    dependencies: [
        .package(path: "../DocumentCore"),
        .package(path: "../DocumentRuntime"),
    ],
    targets: [
        .target(
            name: "HWPDocument",
            dependencies: [
                .product(name: "DocumentCore", package: "DocumentCore"),
                .product(name: "DocumentRuntime", package: "DocumentRuntime"),
            ]
        ),
        .testTarget(
            name: "HWPDocumentTests",
            dependencies: [
                "HWPDocument",
                .product(name: "DocumentCore", package: "DocumentCore"),
                .product(name: "DocumentRuntime", package: "DocumentRuntime"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
