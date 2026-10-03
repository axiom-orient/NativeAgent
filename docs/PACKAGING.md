# SwiftPM distribution

## Remote product

The repository root is a package collection, not one runtime or one public API
module. Its root `Package.swift` exposes `NativeAgentSumday`. The root manifest
defines the selected dependency targets against their existing source paths, so
a remote Git consumer does not traverse `.package(path:)` edges. The product adds
no provider routing, credential state, storage, or runtime lifecycle.

Add the repository once as an SPM dependency and select
`NativeAgentSumday`. App source continues to import concrete modules, for
example `NativeAgent`, `NativeAgentDomain`, `LanguageModelRuntime`, `ASK`,
`ChatGPTText`, or `NativeAgentUI`. The selected product is a package-graph
composition for Sumday, not a replacement facade API.

The remote root exposes only this composition product. Nested package manifests
remain for local development and focused qualification; their source targets
are referenced directly by the root distribution manifest. SwiftPM does not let
a Git URL select an arbitrary nested `Package.swift`. Add another remote
composition only when a real consumer and its exact product closure are
established.

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
The flattened root manifest contains 34 targets (the 33-target selected module
closure plus `NativeAgentSumday`) and resolves its six pinned transitive package
versions locally. The app's remote Xcode resolution is still pending. The next
release candidate is `0.1.1`; publish its tag only after remote Xcode resolution
and owner review. Do not retarget a published tag.

`swift build` or package tests verify only the executed package/host boundary.
Apple SDK compilation, native callbacks, Keychain, device lifecycle, account
access, and live provider effects have separate gates in
[`production/QUALIFICATION.md`](production/QUALIFICATION.md). A source release
does not convert a remaining native/live gate into PASS. No CI workflow or
automated GitHub release is part of this package.
