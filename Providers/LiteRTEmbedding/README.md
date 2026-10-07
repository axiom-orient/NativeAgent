# LiteRTEmbeddingProvider

Optional local text embedding adapter for the **generic EmbeddingGemma 2 text 270M**
artifact and official LiteRT-LM **0.18.0** C embedding engine. It neither imports nor
calls the text generation adapter. Both independent adapters now consume the same
0.18.0 binary from `LiteRTNative`. iOS/macOS builds require that pinned library; missing
binaries or older C interfaces fail compilation rather than selecting a compatibility path.

The root `NativeAgent` manifest exposes `EmbeddingCore` and `LiteRTEmbeddingProvider`
as separate products. The adapter uses the existing ModelArtifactStore for verified
artifact preparation/leases and Hugging Face for the explicit fixed-revision download.
Agent, ASK, application databases and remote embedding services remain absent.

```swift
import EmbeddingCore
import LiteRTEmbeddingProvider
import ModelArtifactStore

let store = try ModelArtifactStore(rootURL: modelStoreDirectory)
try await EmbeddingGemma2.prepare(in: store) // explicit download; verified cache is reused
let model = try await LiteRTEmbeddingModel.load(
  store: store, cacheDirectory: existingWritableCacheDirectory, dimensions: .d256)
let vectors = try await model.embed([
  .document(text: "회의 전에 설계 문서를 읽는다.", title: "회의 준비"),
  .document(text: "주말에 한강에서 달린다.", title: "운동")
])
var index = try EmbeddingIndex(profile: model.profile)
try index.upsert([
  .init(id: "meeting", vector: vectors[0]),
  .init(id: "exercise", vector: vectors[1])
])
let query = try await model.embed(.query("회의 준비 자료"))
let matches = try index.search(query, limit: 3)
let snapshot = try JSONEncoder().encode(index) // host chooses storage and document-ID mapping
try await model.shutdown() // drains inference before releasing the model file lease
```

`prepare(in:)` publishes only the exact size/SHA-verified immutable artifact. Only a
missing cache downloads; corrupt cache, network, storage and cancellation failures
propagate without redownload/repair fallback. `importArtifact(from:into:)` prepares
an already-present exact file without network. Publication can finish before a late
cancellation is observed; cancellation does not promise to remove committed bytes.
`load(store:)` never downloads and owns its ArtifactLease until native shutdown, so
store removal is rejected while the engine is resident. The existing `load(modelURL:)`
path remains for hosts that explicitly own immutable external files.

Batches contain 1...64 inputs and preserve order. All inputs validate before inference.
One admission covers the entire batch: concurrent calls fail busy; cancellation joins
the current native call, stops remaining items and returns no partial vector array.
An overflow in any input fails the batch; there is no truncation or chunk averaging.

MRL dimensions `.d128`, `.d256`, `.d512`, `.d768` select independent exact profiles.
The default remains 256D. Every result validates the full 768D native output before
truncation and L2 normalization. Mixed dimension/profile indices are rejected.

`EmbeddingIndex` is a host-owned in-memory exact cosine index with stable ties,
atomic bulk upsert, remove and validated Codable restoration. It stores vectors/IDs,
not document text or a database. An optional minimumSimilarity is caller-calibrated;
no threshold guarantees relevance. This small-corpus index is not an ANN database.
A RAG host resolves returned IDs to its own text and supplies that context through the
existing Agent/model API; the kernel does not load or route embedding providers.

## Frozen profile

- Artifact repository: `litert-community/embeddinggemma-2-text-270m-litert-lm`
- Revision: `9be6e8b90982095dc05c2bd162e4b954ee4dbac7`
- File: `embeddinggemma-2-text-270m.litertlm`, **164,626,432 bytes**
- SHA-256: `2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb`
- CPU only, two threads, FLOAT32 activation; artifact contains INT4 weight tensors.
- Full native output **768D**, selected leading **128/256/512/768D**, then L2 normalization and validation.
- Trim surrounding whitespace; insert native BOS/EOS; maximum **1024 tokens including
  prefixes and special tokens**. Overflow returns the native error, without truncation
  or chunk averaging. The artifact contains signatures up to 8192, but its metadata
  default is 1024 and this adapter explicitly fixes that resource/input policy.
- Query: `task: search result | query: {query}`
- Document: `title: {title or none} | text: {content}`
- Prompt revision: `google-model-card-2-20261006-search-v1`

The [official model card](https://ai.google.dev/gemma/docs/embeddinggemma/model_card_2)
and [LiteRT examples](https://developers.google.com/edge/litert-lm/embedding_models)
have different prompt dialects. The exact artifact's metadata has BOS/EOS, model-family
and maximum-length settings, **no task-prefix template**. This adapter deliberately
freezes the model-card dialect. Changing it requires a new profile and explicit index
rebuild; no equivalence with LiteRT's `task: search query | text:` dialect is assumed.

Family-level native capability flags report vision/audio even for this artifact. Actual
sections contain only tokenizer, text encoder and embedder. The locked digest and
text-only public input prevent treating family flags as usable multimodal encoders.

## Lifetime and supported boundaries

`LiteRTEmbeddingModel` owns admission, its one inference task and shutdown. A second
request fails with `busy`. A private serial queue confines all C pointers and I/O.
The C embedding API has no cancel function: cancellation discards output only after the
native call returns. It cannot promise prompt preemption. Shutdown joins that return
before deleting the engine. Concurrent/cancelled shutdown waiters join one teardown.
A release failure stays closed/failed and is not reset by another caller.

The text and embedding leaf packages share `../LiteRTNative`; neither frontend
redeclares upstream binaries. Root distribution exposes both products over one native
binary declaration. Both are qualified together with separate resident/operation owners;
sharing a library does not merge model state or allow one caller to release another engine.

GPU/NPU, other models/quantizations, multimodal input and production
search thresholds are outside this profile. Relevant synthetic retrieval matches are
not evidence of reliable abstention or general Korean search quality.

See [verification](../../Qualification/LiteRTUnified/README.md) and
[the current combined report](../../docs/verification/current/litert-release-20261007/REPORT.md).
