// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASKHWPSampleConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/HWPDocument")
    ],
    targets: [
        .executableTarget(
            name: "HWPSampleConsumer",
            dependencies: ["HWPDocument"]
        )
    ]
)
