# LiteRTProvider

Optional local text generation provider using the shared `../LiteRTNative` package,
currently official LiteRT-LM **0.18.0**. The embedding provider shares that same native
library; the two frontends can be linked together without duplicate upstream targets.

The existing `LiteRTTextModel`, connector, LocalBackend and ModelRuntime contracts stay
intact. Model selection, artifact acquisition, host cache and residency remain explicit.
CPU/GPU text generation, greedy sampling, constrained JSON and qualified-tool rendering
use the actual C engine/conversation APIs. No embedding is generated through this adapter.

`LiteRTProvider.upstreamVersion` and result metadata use `LiteRTNativeRuntime.version`.
Runtime admission/cancel/drain belongs to ModelRuntime, and cleanup frees this engine only.
Text cancellation invalidates the engine after native completion; the host explicitly
reloads. It does not cancel or unload an independent embedding resident.

Root consumers select `LiteRTProvider` and optionally `LiteRTEmbeddingProvider`. Leaf
source consumers select both packages in one exported closure so they share LiteRTNative.
Core/runtime/artifact/Hub manifests now declare macOS 13 for their Duration-based APIs;
the concrete provider and root distribution retain macOS 15 / iOS 17 floors.

```sh
swift test --package-path Providers/LiteRT -Xswiftc -warnings-as-errors
python3 Qualification/LiteRTUnified/check_runtime.py --check-latest
```

[Current real-model qualification](../../docs/verification/current/litert-release-20261007/REPORT.md)
distinguishes CPU/GPU execution from controlled contract tests. Tool model quality,
multimodal parity and every model family are not certified by one text artifact.
[Shared binary provenance](../LiteRTNative/README.md) is the current pin authority. Keep
the official framework's LICENSE/third_party_licenses.bundle when redistributing it.
