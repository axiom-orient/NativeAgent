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
`ModelArtifactStore`, `EmbeddingCore`, `LiteRTProvider`, `LiteRTEmbeddingProvider`, `LEAPProvider`, `ChatGPTAccount`, `ChatGPTText`,
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
selected modules directly from the repository source tree and declares only its
two upstream remote packages. The prior path-based root was rejected by SwiftPM
for tag, branch, and revision requirements and its `0.1.0` tag was withdrawn.
The flattened root references the independent source modules and declares each upstream
binary once. LiteRT text and embedding share the same 0.18.0 binary identity through
`Providers/LiteRTNative`; they keep separate inference and resource owners. Consumers pin
a reviewed source commit or a qualified preview tag.
Publishing source products does not certify all optional native/live effects.
Publish a semantic release tag only after its qualification scope is reviewed;
do not retarget a published tag.

`swift build` or package tests verify only the executed package/host boundary.
Apple SDK compilation, native callbacks, Keychain, device lifecycle, account
access, and live provider effects have separate gates in
[`production/QUALIFICATION.md`](production/QUALIFICATION.md). A source release
does not convert a remaining native/live gate into PASS. No CI workflow or
automated GitHub release is part of this package.
