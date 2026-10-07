# Unified LiteRT release qualification

Production text and embedding products, in the same process, with separate residents.
No mocks, user records, DB, network embeddings or production fallback are used by this
consumer. Synthetic prompts verify CPU/GPU text, constrained JSON, cancellation/join,
explicit text reload and embedding use after the text engine closes.

## Exact text artifact

- Public `litert-community/Qwen3-0.6B`
- Repository revision `a3c5d805ae362dff7f580bc25f2dfb9a5a7eaa76`
- `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm`, 344,671,744 bytes
- SHA-256 `03e7da1eb1108b50dffaa9bb52cc7bcbad2eb0c66ca990267f480c1e545d2856`
- Native metadata: LLM, dynamic 4096 context, minimum runtime requirement absent.

The embedding artifact/profile is defined by [EmbeddingGemma2](../../Providers/LiteRTEmbedding/README.md).
Model bytes remain outside the source tree and must match the recorded identities.

```sh
swift test --package-path Providers/LiteRT -Xswiftc -warnings-as-errors
swift test --package-path Providers/LiteRTEmbedding -Xswiftc -warnings-as-errors
python3 Qualification/LiteRTUnified/check_runtime.py --check-latest
python3 Qualification/LiteRTUnified/test_runtime_manifest.py
swift run --package-path Qualification/LiteRTUnified LiteRTUnifiedCLI \
  /absolute/text-model.litertlm /absolute/embedding-model.litertlm /absolute/cache
# Add a fifth argument "gpu" for an explicit GPU text run.
```

The iOS app bundles both exact artifacts and imports the root concrete products. It
executes CPU and GPU text sequences; embeddings use the fixed CPU profile. It stores
reports only in its own `Library/Caches/litert-unified-report.json`. Use an independently
available physical device; never take another chat's simulator custody. Official iOS
binaries have arm64 slices only, so simulator compile/link is scoped to arm64.

Initial command failures (underdeclared macOS floor, an invalid fixture deadline and an
unsupported x86_64 simulator build) are preserved in the full logs. The macOS floor was
fixed in the manifests, the fixture now follows the public request limits, and arm64
matches the official artifact and the user's permitted simulators. None is an inference
fallback. [Current results](../../docs/verification/current/litert-release-20261007/REPORT.md).
