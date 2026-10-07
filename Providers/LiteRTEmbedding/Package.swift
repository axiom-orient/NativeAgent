// swift-tools-version: 6.2
import PackageDescription

let core: Target.Dependency = .product(name: "EmbeddingCore", package: "EmbeddingCore")
var dependencies: [Target.Dependency] = [core, .product(name: "LiteRTNative", package: "LiteRTNative")]
var targets: [Target] = []
#if os(macOS)
  dependencies += [
    .product(name: "CLiteRTLM", package: "LiteRTNative", condition: .when(platforms: [.iOS])),
    .product(name: "CLiteRTLM_mac", package: "LiteRTNative", condition: .when(platforms: [.macOS])),
  ]
#endif
targets += [
  .target(name: "LiteRTEmbeddingProvider", dependencies: dependencies),
  .testTarget(name: "LiteRTEmbeddingProviderTests", dependencies: ["LiteRTEmbeddingProvider", core]),
]
let package = Package(
  name: "LiteRTEmbeddingProvider",
  platforms: [.iOS(.v17), .macOS(.v15)],
  products: [.library(name: "LiteRTEmbeddingProvider", targets: ["LiteRTEmbeddingProvider"])],
  dependencies: [
    .package(name: "EmbeddingCore", path: "../../Model/EmbeddingCore"),
    .package(name: "LiteRTNative", path: "../LiteRTNative"),
  ],
  targets: targets,
  swiftLanguageModes: [.v6]
)
