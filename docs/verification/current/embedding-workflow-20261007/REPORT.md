# NativeAgent 0.1.3 — EmbeddingGemma 2 workflow

Scoped enhancement from source `c99dfcf89a800de1689a2b9370b93284fc9f0d8e`.
Unrelated local staging and consumer pins are preserved. No CI/workflows, migrations,
model weights or remote embedding service are added.

## Completed behavior

- Explicit fixed-revision model download/import and verified publication through the
  existing ModelArtifactStore. Only an absent artifact downloads; corruption fails
  without redownload. Store-backed load never downloads and retains its own lease
  until native shutdown. Active engines prevent artifact removal.
- Ordered 1...64-input batching under one existing model admission. All inputs validate
  before native I/O. Cancellation joins the current C call, stops later items and
  returns no partial result. Shutdown continues to stop intake/drain/release once.
- Native 768D FLOAT32 output validates before leading 128/256/512/768D MRL selection
  and L2 normalization. Default 256D profile stays unchanged. Every selected profile
  rejects mixed dimensions/settings.
- Host-owned EmbeddingIndex performs exact cosine ranking with stable ties, optional
  caller-calibrated filtering, atomic bulk upsert, removal and validated Codable v1
  snapshots. Unknown formats, duplicate IDs and foreign vector profiles fail. The
  SDK does not own a database, store document text or migrate an old index.
- Reproducible workflow command is part of the existing LiteRTUnified qualifier;
  Korean corpus fixtures are shared with existing inference/lifecycle qualification.
  The host resolves returned IDs to its documents for the existing Agent/model API;
  kernel/provider ownership boundaries remain intact.

## Actual verification

| Check | Result |
|---|---|
| EmbeddingCore values/index | PASS: 8 tests |
| Provider input/batch/artifact/lifecycle | PASS: 12 tests |
| Manifest/distribution/closure | PASS: 7 / 7 / 9 cases |
| Canonical document/source/syntax guards | PASS |
| Current signed iOS build | PASS: root concrete products |
| macOS real model | PASS: download/prepare, store-backed load, all four MRL profiles, batch documents/queries, snapshot restore, Korean 8/8 at each dimension, active lease removal rejection and post-shutdown removal |
| iPhone 15 / iOS 27.0.1 real model | PASS: same complete workflow and 8/8 at all four dimensions |
| Checked-in qualifier | PASS: current real model workflow |

Frozen artifact: `litert-community/embeddinggemma-2-text-270m-litert-lm`, revision
`9be6e8b90982095dc05c2bd162e4b954ee4dbac7`, 164626432 bytes, SHA-256
`2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb`.
Runtime is official LiteRT-LM 0.18.0, CPU two threads, FLOAT32 activation, native
768D; INT4 weights. Prompts use the fixed model-card search-query/document dialect.
1024 tokens include prefixes/BOS/EOS; overflow fails without truncation/averaging.

These synthetic 8-document tests prove pipeline/lifecycle behavior and fixture ranking,
not general relevance, abstention or production RAG quality. Index search is exact
in-memory small-corpus retrieval, not an ANN database. GPU/NPU, multimodal artifacts,
other model/quantization profiles and every model family remain outside this scope.
Native embeddings never upload document/query content. Full failed/original logs and
scratch applications remain separate local evidence; no user data or credentials are
included. Prior release tags stay immutable.
