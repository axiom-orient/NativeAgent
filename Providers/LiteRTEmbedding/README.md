# LiteRTEmbeddingProvider

Optional local text embedding adapter for the **generic EmbeddingGemma 2 text 270M**
artifact and official LiteRT-LM **0.18.0** C embedding engine. It neither imports nor
calls the text generation adapter. Both independent adapters now consume the same
0.18.0 binary from `LiteRTNative`. Swift/C embedding APIs already exist in the official 0.17.0 source;
0.18.0 adds announced EmbeddingGemma 2 support, not the first embedding API.

The root `NativeAgent` manifest exposes `EmbeddingCore` and `LiteRTEmbeddingProvider`
as separate products. This leaf package depends only on `EmbeddingCore` and the pinned
Apple binary. Agent, ASK, application databases and remote embedding services are absent.

```swift
import EmbeddingCore
import LiteRTEmbeddingProvider

let model = try await LiteRTEmbeddingModel.load(
  modelURL: localImmutableModelURL,
  cacheDirectory: existingWritableCacheDirectory)
let document = try await model.embed(.document(text: "회의 전에 설계 문서를 읽는다."))
let query = try await model.embed(.query("회의 준비 자료"))
try document.validate(for: model.profile) // before inserting into this profile's index
let score = try query.cosineSimilarity(to: document)
try await model.shutdown() // explicit host-owned lifetime
```

The host obtains the model and maintains its immutable bytes until shutdown. Loading
checks size, SHA-256 and actual native model type/dimension before engine creation.
No download, automatic routing, remote upload or silent fallback is performed.

## Frozen profile

- Artifact repository: `litert-community/embeddinggemma-2-text-270m-litert-lm`
- Revision: `9be6e8b90982095dc05c2bd162e4b954ee4dbac7`
- File: `embeddinggemma-2-text-270m.litertlm`, **164,626,432 bytes**
- SHA-256: `2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb`
- CPU only, two threads, FLOAT32 activation; artifact contains INT4 weight tensors.
- Full native output **768D**, leading **256D**, then L2 normalization and validation.
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

GPU/NPU, other dimensions/models/quantizations, multimodal input and production
search thresholds are outside this profile. Relevant synthetic retrieval matches are
not evidence of reliable abstention or general Korean search quality.

See [verification](../../Qualification/LiteRTUnified/README.md) and
[the current combined report](../../docs/verification/current/litert-release-20261007/REPORT.md).
