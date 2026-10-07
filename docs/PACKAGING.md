# SwiftPM distribution

## Remote product

The repository root is a package collection, not one runtime or one public API
module. Its root `Package.swift` exposes independent concrete products. The root manifest
defines the selected dependency targets against their existing source paths, so
a remote Git consumer does not traverse `.package(path:)` edges. The product adds
no provider routing, credential state, storage, or runtime lifecycle.

Add the repository once as an SPM dependency and select only the products needed
by each consumer target. Products include `NativeAgent`, `NativeAgentDomain`,
`NativeAgentManager`, `LanguageModelCore`, `LanguageModelRuntime`,
`ModelArtifactStore`, `EmbeddingCore`, `LiteRTProvider`, `LiteRTEmbeddingProvider`, `MLXProvider`, `MLXModelRegistry`, `LEAPProvider`, `ChatGPTAccount`, `ChatGPTText`,
`ChatGPTTextProvider`, `ChatGPTImage`, `ChatGPTImageCapability`,
`AppleSystemModelProvider`, `ASK`, `NativeAgentUI`, and `NativeAgentPresentation`.
App source imports the same concrete module names. There is no app-specific
distribution product or umbrella runtime. Consumer composition stays in the app.

Nested package manifests remain for local development and focused qualification; their source targets
are referenced directly by the root distribution manifest. SwiftPM does not let
a Git URL select an arbitrary nested `Package.swift`. Do not combine remote root
products with source copies of the same leaf packages.

```swift
.package(url: "https://github.com/axiom-orient/NativeAgent.git", revision: "<reviewed-commit>")
// Select capabilities directly used by this consumer target:
.product(name: "NativeAgent", package: "NativeAgent"),
.product(name: "ChatGPTTextProvider", package: "NativeAgent"),
.product(name: "AppleSystemModelProvider", package: "NativeAgent"),
```

Core keeps request/event/schema values. Runtime owns invocation lifecycle, Agent
owns approval/effect state, providers own external I/O, and SDK UI owns presentation.
Core and the Agent kernel must not acquire provider, knowledge, UI, or consumer
dependencies. `AppleSystemModelProvider` retains its availability gates; product
selection does not prove device/model availability or inference success.

## Source package closures

For a local consumer that needs another package combination, use
`tools/package-closure.py` rather than copying one directory. It follows the
actual manifests and preserves the selected graph, lockfiles, resources,
tests, licenses, notices, and relative paths.

```sh
# Run from the repository root. Write output outside the source tree.
python3 tools/package-closure.py \
  --entry Model/NativeLanguageModels \
  --output ../NativeLanguageModels.zip

python3 tools/package-closure.py \
  --entry Providers/ChatGPT/Text \
  --entry Providers/ChatGPT/Image \
  --output ../ChatGPTTextAndImage.zip

python3 tools/package-closure.py \
  --entry Agent/NativeAgentPackage/Packages/ChatGPTAgent \
  --entry Agent/NativeAgentPackage/Packages/ChatGPTImageCapability \
  --output ../ChatGPTAgent.zip
```

The bundler uses `swift package dump-package` to follow local dependencies.
It rejects existing outputs, symlinks, source-root escapes, and manifests that
change while evaluation is running. `BUNDLE.json` records selected entries,
graph, hashes, and remote dependencies. A source bundle is not a GitHub
release or an external consumer qualification.

Do not add separate copies of shared dependencies from multiple bundles. When
Text and Image are used together, select both in one closure so they share one
ChatGPT Account package and one host-owned account session.

## Version and release boundary

The root distribution graph has no local package dependencies. It targets the
selected modules directly from the repository source tree and declares the current upstream packages. The prior path-based root was rejected by SwiftPM
for tag, branch, and revision requirements and its `0.1.0` tag was withdrawn.
The flattened root references the independent source modules and declares each upstream
binary once. LiteRT text and embedding share the same 0.18.0 binary identity through
`Providers/LiteRTNative`; they keep separate inference and resource owners. Consumers pin
a reviewed source commit or release tag.
Publishing source products does not certify all optional native/live effects.
Publish a semantic release tag only after its qualification scope is reviewed;
do not retarget a published tag.

`swift build` or package tests verify only the executed package/host boundary.
Apple SDK compilation, native callbacks, Keychain, device lifecycle, account
access, and live provider effects have separate gates in
[`production/QUALIFICATION.md`](production/QUALIFICATION.md). A source release
does not convert a remaining native/live gate into PASS. No CI workflow or
automated GitHub release is part of this package.

## Current NativeAgent 0.1.2

```swift
.package(url: "https://github.com/axiom-orient/NativeAgent.git", exact: "0.1.2")
```

The supported LiteRT baseline is the official 0.18.0 library, shared by text and
embedding products. Lower LiteRT versions are not supported; iOS/macOS compilation
requires the declared native module. Platform-unavailable hosts remain explicitly
unavailable, without a provider fallback. Existing preview tags are historical artifacts.

## NativeAgent 0.1.2 native baseline

MLX Swift 0.32.3, MLX Swift LM 3.32.3 and Hugging Face 0.13.0 are exact dependencies. Transformers 1.3.4 and LiteRT-LM 0.18.0 remain current. LEAP 0.11.0-SNAPSHOT is the latest upstream prerelease and uses a sibling inference_engine framework. Root products now include MLXProvider and MLXModelRegistry. No migration/older-library compatibility packages or nested LEAP signing helper are provided. Version 0.1.1 remains immutable history.

The current root distribution requires Swift 6.3, iOS 26.5 and macOS 26.0. The official LEAP 0.11 inference_engine Mach-O declares these OS floors, despite the upstream package declaration; NativeAgent follows the actual binary. Independent MLX and LiteRT source packages retain their own supported OS floors.

The remaining direct remote SDK dependencies are Swift Markdown 0.9.0 and SwiftMCP 0.4.2. The SwiftMCP upstream comparison contains only its two README changes; no runtime/API change or migration is introduced. Parser and MCP adapters are verified separately from native inference.
