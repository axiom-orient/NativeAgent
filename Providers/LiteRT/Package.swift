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

// CLiteRTLM is an Apple XCFramework. Do not make Linux package inspection or
// contract tests fetch an unusable Apple artifact. macOS hosts (the supported
// iOS build environment) receive the official v0.17.0 iOS/macOS binaries.
// The upstream Swift wrapper 0.17.1 uses these same native artifacts.
#if os(macOS)
  targets.append(
    .binaryTarget(
      name: "CLiteRTLM",
      url:
        "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.17.0/CLiteRTLM.xcframework.zip",
      checksum: "c94fc12aa0403cb47208e419cc3bfe258214ea17035f7a63c16de536869f2186"
    )
  )
  targets.append(
    .binaryTarget(
      name: "CLiteRTLM_mac",
      url:
        "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.17.0/CLiteRTLM_mac.xcframework.zip",
      checksum: "83efd536485c9d58fcd7fb7d4556ddb16ca46bb775b0449d08d9825c6836c1a4"
    )
  )
  providerDependencies.append(.target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])))
  providerDependencies.append(.target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS])))
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
    .package(name: "LanguageModelCore", path: "../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../Model/LanguageModelRuntime"),
    .package(name: "ModelArtifactStore", path: "../../Model/ModelArtifactStore"),
    .package(name: "ModelHub", path: "../../Model/ModelHub"),
    .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.10.2", traits: []),
  ],
  targets: targets,
  swiftLanguageModes: [.v6]
)
