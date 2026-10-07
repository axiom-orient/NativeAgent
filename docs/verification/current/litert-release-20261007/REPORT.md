# NativeAgent 0.1.1 — LiteRT 0.18.0 qualification

Candidate based on published NativeAgent `98dafa0`, containing only scoped LiteRT
text/embedding changes. Unrelated local staged changes are excluded. Release review
and exact-candidate execution results are recorded here before GitHub publication.

## Cleanup

- One shared 0.18.0 binary owner for the independent text and embedding adapters.
- One qualification CLI/app; it now covers Korean retrieval and embedding lifecycle
  along with CPU/GPU text, constrained JSON, cancellation and resident independence.
- Removed the obsolete 0.15.0 SBOM/notice payloads; preserved original records outside
  source. The current upstream LICENSE and framework notice-bundle requirements remain.
- Direct ModelRuntime client binding avoids a redundant language-model wrapper.
- Core/runtime/artifact/Hub manifests explicitly declare the macOS 13 floor required
  by Duration-based APIs; root/concrete providers retain macOS 15 and iOS 17.

This is the NativeAgent 0.1.1 release with a scoped LiteRT qualification, not a certification of
all optional providers, live accounts, user-corpus search quality or future releases.
The root production gates remain separate. No CI/workflow or Sumday pin update is added.

## Exact-candidate verification

| Check | Result |
|---|---|
| Text / embedding / embedding values | PASS: 8 / 6 / 5 tests |
| Core / Runtime / ArtifactStore / Hub | PASS: 57 / 100 / 19 / 13 tests |
| Native manifest consistency | PASS: 7 regression cases and live official release/digest comparison |
| Distribution / package closure guards | PASS: 5 / 9 tests |
| macOS CPU/GPU + CPU embedding | PASS: real artifacts; constrained JSON, cancel/drain/reload; Korean fixture 8/8 |
| iPhone 15 / iOS 27.0.1 | PASS: release-candidate root products, CPU/GPU text + CPU embedding, same lifecycle and 8/8 fixture |
| iOS Simulator arm64 | PASS: compile/link only; no shared-device launch or control |
| Relocated source closure | PASS: real CPU model run from the exported nine-package source graph |
| Boundary / syntax / document checks | PASS on the isolated candidate |

The unrelated Korean query has no relevant document and still returns a high similarity;
8/8 positives are not a general search-quality or abstention guarantee. NPU, embedding
GPU, every model family, live accounts and whole-SDK release gates are not certified.

Models are acquired separately. Text SHA-256:
`03e7da1eb1108b50dffaa9bb52cc7bcbad2eb0c66ca990267f480c1e545d2856`;
embedding SHA-256:
`2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb`.
Actual reports here are synthetic; no user content, raw credentials or device identifiers
are published. Original full logs and the retired records remain in the local evidence
archive. Future releases require explicit checksum/API/compile/runtime qualification.

The original source guard's LeapSDK count did not account for the published flattened
root mirror. It now verifies the exact root/leaf owner set and matching URL/checksum;
it does not ignore a duplicate or relax the native artifact identity. Validation output
can be isolated without overwriting another task's current evidence.

## 0.1.1 finalization

The release version is 0.1.1, without a prerelease suffix. All supported iOS/macOS
paths require the official 0.18.0 C module directly. Removed module-presence fallback
and the obsolete 0.17 DeviceQualification project; the unified native qualification
is the single current verification entry. Unsupported platforms remain unavailable.
The older preview tag is preserved as immutable history, not a compatibility option.

Final 0.1.1 source passed current macOS CPU/GPU real-model runs and iPhone 15 CPU/GPU
execution after a transient disconnect/locked-device retry. The report file was read
from that app only after the successful current-source launch. Required-native-module
negative typechecking fails as expected; no module-presence fallback remains.
