// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKFacadeConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "FacadeConsumer",
            dependencies: [.product(name: "ASK", package: "ASK")]
        )
    ]
)
