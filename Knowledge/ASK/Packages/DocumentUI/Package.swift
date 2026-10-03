// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DocumentUI",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "DocumentUI", targets: ["DocumentUI"])],
    dependencies: [
        .package(path: "../DocumentCore"),
        .package(path: "../HWPDocument"),
    ],
    targets: [
        .target(
            name: "DocumentUI",
            dependencies: [
                .product(name: "DocumentCore", package: "DocumentCore"),
                .product(name: "HWPDocument", package: "HWPDocument"),
            ]
        ),
        .testTarget(name: "DocumentUITests", dependencies: ["DocumentUI"]),
    ],
    swiftLanguageModes: [.v6]
)
