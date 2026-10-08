// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let extensionProducts = [
  "NativeAgentManager",
  "NativeAgentMemory",
  "NativeAgentGoals",
  "NativeAgentEvolution",
  "NativeAgentEvolutionSkills",
  "NativeAgentConsensus",
  "NativeAgentSkills",
  "NativeAgentSkillsWeb",
  "NativeAgentBrowser",
  "NativeAgentHTML",
  "NativeAgentTools",
  "NativeAgentWeb",
]

let modelCore: Target.Dependency = .product(
  name: "LanguageModelCore", package: "LanguageModelCore")
let modelRuntime: Target.Dependency = .product(
  name: "LanguageModelRuntime", package: "LanguageModelRuntime")

let package = Package(
  name: "NativeAgentPackage",
  platforms: [.iOS(.v17)],
  products: [.library(name: "NativeAgent", targets: ["NativeAgent"])]
    + [.library(name: "NativeAgentDomain", targets: ["NativeAgentDomain"])]
    + extensionProducts.map { .library(name: $0, targets: [$0]) },
  dependencies: [
    .package(name: "LanguageModelCore", path: "../../Model/LanguageModelCore"),
    .package(name: "LanguageModelRuntime", path: "../../Model/LanguageModelRuntime"),
  ],
  targets: [
    .target(name: "CSQLite", publicHeadersPath: ".", linkerSettings: [.linkedLibrary("sqlite3")]),

    // Minimum durable-Agent kernel.
    .target(name: "NativeAgentDomain", dependencies: [modelCore], swiftSettings: strict),
    .target(
      name: "NativeAgentExecution",
      dependencies: ["NativeAgentDomain", modelRuntime],
      swiftSettings: strict
    ),
    .target(
      name: "NativeAgentStore",
      dependencies: ["NativeAgentDomain", "CSQLite"],
      swiftSettings: strict
    ),
    .target(
      name: "NativeAgent",
      dependencies: [
        modelCore, modelRuntime, "NativeAgentDomain", "NativeAgentExecution", "NativeAgentStore",
      ],
      swiftSettings: strict
    ),

    // Canonical host-facing composition layer. The durable kernel stays provider-neutral;
    // this target owns Agent identity, provider selection, Soul/Memory/Skills workspace assembly.
    .target(
      name: "NativeAgentManager",
      dependencies: ["NativeAgent", "NativeAgentDomain", "NativeAgentSkills", modelCore, modelRuntime],
      resources: [.copy("ResponsePolicies")],
      swiftSettings: strict
    ),

    // Optional subsystems. None are dependencies of the minimum kernel above.
    .target(
      name: "NativeAgentMemoryProjection",
      dependencies: ["CSQLite"],
      swiftSettings: strict
    ),
    .target(
      name: "NativeAgentMemory",
      dependencies: [
        "NativeAgentDomain", "NativeAgentMemoryProjection", "NativeAgent", modelRuntime,
      ],
      swiftSettings: strict
    ),
    .target(
      name: "NativeAgentGoals",
      dependencies: ["NativeAgentDomain", "NativeAgentExecution", modelRuntime],
      swiftSettings: strict
    ),
    .target(
      name: "NativeAgentEvolution",
      dependencies: ["NativeAgentDomain", modelRuntime],
      swiftSettings: strict
    ),
    .target(
      name: "NativeAgentEvolutionSkills",
      dependencies: ["NativeAgentDomain", "NativeAgentEvolution", "NativeAgentSkills"],
      swiftSettings: strict
    ),
    .target(name: "NativeAgentConsensus", dependencies: ["NativeAgentDomain"], swiftSettings: strict),
    .target(name: "NativeAgentTools", dependencies: ["NativeAgentDomain"], swiftSettings: strict),
    .target(name: "NativeAgentSkills", dependencies: ["NativeAgentDomain", modelCore], swiftSettings: strict),
    .target(
      name: "NativeAgentSkillsWeb",
      dependencies: ["NativeAgentDomain", "NativeAgentSkills"],
      swiftSettings: strict
    ),
    .target(name: "NativeAgentBrowser", dependencies: ["NativeAgentDomain"], swiftSettings: strict),
    .target(
      name: "NativeAgentHTML",
      dependencies: ["NativeAgentDomain", "NativeAgentBrowser"],
      swiftSettings: strict
    ),
    .target(name: "NativeAgentWeb", dependencies: ["NativeAgentDomain"], swiftSettings: strict),

    .target(
      name: "NativeAgentTestSupport",
      dependencies: ["NativeAgent", "NativeAgentDomain", "NativeAgentExecution", "NativeAgentStore", modelCore, modelRuntime],
      path: "Tests/Support/NativeAgentTestSupport",
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentManagerTests",
      dependencies: [
        "NativeAgentManager", "NativeAgent", "NativeAgentDomain", "NativeAgentSkills",
        "NativeAgentTestSupport", modelCore, modelRuntime,
      ],
      resources: [.copy("Fixtures")],
      swiftSettings: strict
    ),
    .testTarget(
      name: "LanguageModelRuntimeTests",
      dependencies: [
        "NativeAgent", "NativeAgentDomain", "NativeAgentExecution", "NativeAgentStore",
        modelCore, modelRuntime,
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentTests",
      dependencies: [
        "NativeAgent", "NativeAgentDomain", "NativeAgentExecution", "NativeAgentStore",
        "NativeAgentTestSupport",
      ],
      swiftSettings: strict
    ),
    .testTarget(name: "NativeAgentDomainTests", dependencies: ["NativeAgentDomain"], swiftSettings: strict),
    .testTarget(
      name: "NativeAgentExecutionTests",
      dependencies: [
        "NativeAgent", "NativeAgentDomain", "NativeAgentExecution", "NativeAgentStore", "NativeAgentTools",
        "NativeAgentMemory", "NativeAgentTestSupport",
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentGoalsTests",
      dependencies: [
        "NativeAgentDomain", "NativeAgentExecution", "NativeAgentStore", "NativeAgentGoals",
        "NativeAgentTestSupport",
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentEvolutionTests",
      dependencies: ["NativeAgentDomain", "NativeAgentEvolution", "NativeAgentTestSupport"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentEvolutionSkillsTests",
      dependencies: [
        "NativeAgentDomain", "NativeAgentEvolution", "NativeAgentEvolutionSkills",
        "NativeAgentSkills",
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentStoreTests",
      dependencies: ["NativeAgentDomain", "NativeAgentStore"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentMemoryTests",
      dependencies: [
        "NativeAgent", "NativeAgentDomain", "NativeAgentMemory", "NativeAgentMemoryProjection",
        "NativeAgentTestSupport",
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentMemoryProjectionTests",
      dependencies: ["NativeAgentMemoryProjection"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentToolsTests",
      dependencies: ["NativeAgentDomain", "NativeAgentTools"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentTestSupportTests",
      dependencies: ["NativeAgentDomain", "NativeAgentTestSupport"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentConsensusTests",
      dependencies: [
        "NativeAgentDomain", "NativeAgentExecution", "NativeAgentStore", "NativeAgentTools",
        "NativeAgentTestSupport", "NativeAgentConsensus",
      ],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentSkillsTests",
      dependencies: ["NativeAgentSkills", "NativeAgent", "NativeAgentDomain", "NativeAgentTestSupport"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentSkillsWebTests",
      dependencies: ["NativeAgentDomain", "NativeAgentSkills", "NativeAgentSkillsWeb"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentBrowserTests",
      dependencies: ["NativeAgent", "NativeAgentBrowser", "NativeAgentDomain", "NativeAgentTestSupport"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentHTMLTests",
      dependencies: ["NativeAgentHTML", "NativeAgentBrowser", "NativeAgentDomain"],
      swiftSettings: strict
    ),
    .testTarget(
      name: "NativeAgentWebTests",
      dependencies: ["NativeAgentWeb", "NativeAgentDomain"],
      swiftSettings: strict
    ),
  ],
  swiftLanguageModes: [.v6]
)
