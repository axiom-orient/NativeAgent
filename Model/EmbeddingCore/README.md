# EmbeddingCore

Independent text embedding input, profile, vector and local model lifetime contracts.
No Agent, ASK, provider, UI, persistence or network dependency. Root consumers select
`EmbeddingCore`; local development uses this leaf manifest.

`EmbeddingInput.query` and `.document(text:title:)` preserve asymmetric retrieval intent.
The selected provider owns formatting and resource policy.

`EmbeddingVector(nativeValues:profile:)` checks the entire native output dimension and
finite values, keeps the leading MRL dimensions, then L2-normalizes using Double arithmetic.
A zero truncated prefix is an error. Persisted profiles/vectors validate on decoding.

Persist the full `EmbeddingProfile` with an index. Before insert, call
`vector.validate(for: indexProfile)`. `cosineSimilarity(to:)` also checks exact compatibility.
Model, revision, artifact digest, quantization, runtime, prompt, input policy, dimensions or
normalization differences reject comparison; the host must explicitly rebuild the index.
The SDK does not own or migrate an application's database.

An `EmbeddingModel` instance has one host owner. Share it among borrowers; only the host
calls `shutdown()`. Cancellation joins native work before returning. Shutdown closes
admission, cancels its operation, waits for completion, then releases its resource.

```sh
swift test --package-path Model/EmbeddingCore -Xswiftc -warnings-as-errors
```

These are value-contract tests, not actual model inference evidence. See
[qualification](../../Qualification/LiteRTUnified/README.md).
