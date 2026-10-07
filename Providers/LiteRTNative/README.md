# LiteRTNative

The sole native binary owner for the independent LiteRT text and embedding source
packages. Official release **0.18.0** is the latest stable release verified on 2026-10-07.
NativeAgent 0.1.1 requires this version on iOS/macOS; no lower-version compatibility
or missing-native-module fallback is included. This module exposes version identity only; it owns no engine, inference, task, cache,
admission or shutdown authority. Each frontend retains its existing resource owner.

- iOS device + iOS Simulator: official CLiteRTLM 0.18.0, **arm64 only**.
- macOS: official CLiteRTLM_mac 0.18.0, arm64/x86_64 archive.
- Archive checksums are pinned in this manifest and match the official release digests.
- `LiteRTNativeRuntime.version` supplies text result metadata and embedding profile identity.
- Root distribution mirrors the same binary declarations without local package edges.
  Choose the root distribution or a leaf-source closure; do not duplicate both graphs.
- The independent text and embedding packages depend on this same package, allowing
  both frontend products in one application with one C module/library.

## Later releases

An unqualified future version is not silently selected. Run:

```sh
python3 Qualification/LiteRTUnified/check_runtime.py --check-latest
python3 Qualification/LiteRTUnified/test_runtime_manifest.py
```

A newer upstream release causes the identity check to fail until explicitly qualified.
For an upgrade, update this manifest's exact version/checksums, the root mirror and the
version value; then run provider tests and the combined CPU/GPU text + CPU embedding
consumer with exact model artifacts. Verify actual downloaded checksums, C symbols,
compile/link, structured output, cancellation, drain/reload and independent residents.
A changed embedding runtime profile requires an explicitly rebuilt index.

Runtime upgrades are local source changes; no CI/workflow, publishing or consumer pin
update is implied. [Official releases](https://github.com/google-ai-edge/LiteRT-LM/releases)
and [current qualification](../../docs/verification/current/litert-release-20261007/REPORT.md).
