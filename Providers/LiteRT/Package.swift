// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let core: Target.Dependency = .product(name: "LanguageModelCore", package: "LanguageModelCore")
let runtime: Target.Dependency = .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime")
let artifacts: Target.Dependency = .product(name: "ModelArtifactStore", package: "ModelArtifactStore")
let modelHub: Target.Dependency = .product(name: "ModelHub", package: "ModelHub")
let huggingFace: Target.Dependency = .product(name: "HuggingFace", package: "swift-huggingface")

var providerDependencies: [Target.Dependency] = [core, runtime, artifacts, modelHub, huggingFace]
var targets: [Target] = []

// Text and embedding consume the same native package, preventing duplicate
// upstream C modules when both frontend products are linked by one host.
providerDependencies.append(.product(name: "LiteRTNative", package: "LiteRTNative"))
#if os(macOS)
  providerDependencies.append(.product(name: "CLiteRTLM", package: "LiteRTNative", condition: .when(platforms: [.iOS])))
  providerDependencies.append(.product(name: "CLiteRTLM_mac", package: "LiteRTNative", condition: .when(platforms: [.macOS])))
#endif

targets.append(
  .target(
    name: "LiteRTProvider",
    dependencies: providerDependencies,
    swiftSettings: strict
  )
)
targets.append(
  .testTarget(
    name: "LiteRTProviderTests",
    dependencies: ["LiteRTProvider", core, runtime, artifacts, modelHub, huggingFace],
    swiftSettings: strict
  )
)

let package = Package(
  name: "LiteRTProvider",
  platforms: [.iOS(.v17), .macOS(.v15)],
  products: [
    .library(name: "LiteRTProvider", targets: ["LiteRTProvider"])
  ],
  dependencies: [
    .package(name: "LiteRTNative", path: "../LiteRTNative"),
    .package(name: "LanguageModelCore", path: "../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../Model/LanguageModelRuntime"),
    .package(name: "ModelArtifactStore", path: "../../Model/ModelArtifactStore"),
    .package(name: "ModelHub", path: "../../Model/ModelHub"),
    .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.10.2", traits: []),
  ],
  targets: targets,
  swiftLanguageModes: [.v6]
)
