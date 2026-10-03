# SwiftPM distribution

## Remote product

The repository root is a package collection, not one runtime or one public API
module. Its root `Package.swift` adds the `NativeAgentSumday` distribution
product. That product declares the current Sumday dependency closure once while
preserving each package's module and state owner. It adds no provider routing,
credential state, storage, or runtime lifecycle.

Add the repository once as an SPM dependency and select
`NativeAgentSumday`. App source continues to import concrete modules, for
example `NativeAgent`, `NativeAgentDomain`, `LanguageModelRuntime`, `ASK`,
`ChatGPTText`, or `NativeAgentUI`. The selected product is a package-graph
composition for Sumday, not a replacement facade API.

The remote root exposes only this composition product. Nested packages keep
their independent manifests for local development and focused qualification;
SwiftPM does not let a Git URL select an arbitrary nested `Package.swift`.
Add another remote composition only when a real consumer and its exact product
closure are established.

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

The root distribution graph currently uses local path dependencies to its
independent subpackages. SwiftPM therefore rejects it when requested as a stable
Git tag. SumDay consumes the public `main` branch and commits its selected
revision in the app's checked-in `Package.resolved`. Do not claim a semantic
release until the root graph no longer depends on local packages. Do not retarget
a released tag.

`swift build` or package tests verify only the executed package/host boundary.
Apple SDK compilation, native callbacks, Keychain, device lifecycle, account
access, and live provider effects have separate gates in
[`production/QUALIFICATION.md`](production/QUALIFICATION.md). A source release
does not convert a remaining native/live gate into PASS. No CI workflow or
automated GitHub release is part of this package.
