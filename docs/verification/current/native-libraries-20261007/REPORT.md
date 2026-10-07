# NativeAgent 0.1.2 — current dependencies and legacy retirement

Only scoped changes from an isolated clone based on `bf62061f9401f2ee49adb68227b92ccf8629dcf3` are published. Unrelated local staging, consumer pins and stored user data are excluded. No CI/workflow or release automation is added.

| Direct dependency | Selection |
|---|---|
| MLX Swift / MLX Swift LM | exact 0.32.3 / 3.32.3 |
| LEAP SDK / inference_engine | 0.11.0-SNAPSHOT, official latest upstream prerelease |
| Hugging Face / Transformers | exact 0.13.0 / 1.3.4 |
| Swift Markdown / SwiftMCP | exact 0.9.0 / 0.4.2 |
| LiteRT-LM | 0.18.0, already current; both official binary identities rechecked |

The actual LEAP inference_engine Mach-O requires iOS 26.5 / macOS 26.0, exceeding the upstream package declaration. Root/LEAP and qualification apps follow the actual binary. Root requires Swift 6.3 for current MLX. Independent MLX/LiteRT source packages retain their own OS floors. Agent/MCP declares macOS 13 for Core/Duration dependencies instead of an invalid implicit default. No older-library compatibility or migration is supplied.

## Changes

- Root exports MLXProvider and MLXModelRegistry. Exact root/leaf dependencies match.
- LEAP's sibling SDK/engine frameworks are linked and embedded/signed by SwiftPM/Xcode. Obsolete nested-dylib signing script and build phase are removed.
- LEAP uses GenerationConstraint.JsonSchema. Actual native output exposed a JSON Markdown envelope. The vendor boundary classifies and strictly decodes it before structured events: no repair/retry; rejects foreign fences, trailing material, multiple objects, non-objects and output overflow. Ordinary text still streams directly.
- MLX/LEAP bind their existing client directly to ModelRuntime, preserving separate resident ownership and borrowed cleanup.
- Removed 77 tracked MigrationHold files, retired release/guard tools and the old API migration map. Current contracts are [API](../../../API.md). Original retired source is preserved outside the repository; ignored caches and user data are not deleted.
- SwiftMCP upstream 0.4.1...0.4.2 comparison changes only its two READMEs; no runtime/API migration is introduced.

## Verification

| Check | Result |
|---|---|
| MLX contract / handle / registry | PASS: 30 XCTest + 7 handle + 4 registry |
| LEAP contract / handle | PASS: 49 XCTest + 8 handle; actual SDK identity and fragmented JSON regression |
| LiteRT after Hub update | PASS: 8 cases |
| Markdown | PASS: 3 XCTest + 36 Swift Testing cases |
| NativeAgentMCP / ASKMCP | PASS: 6 / 25 cases |
| Distribution / closure / LiteRT manifest | PASS: 7 / 9 / 7 cases |
| macOS real MLX | PASS: GPU text, constrained JSON, real tool proposal, cancel/drain/closed admission/reload |
| macOS real LEAP | PASS: text/JSON, cancel/drain/closed admission/reload |
| macOS LEAP voice | PASS: finite nonzero TTS PCM, synthetic ASR words, S2S text/PCM, cancel/drain/reload/unload |
| iPhone app build / embed/sign | PASS: current root products, actual OS floor, exact bundled model hashes, deep/strict signature |
| Physical iPhone execution | NOT_RUN: app installed; launch disconnected then was rejected because the device is locked |

Real immutable models: Qwen3-0.6B-4bit `73e3e38d981303bc594367cd910ea6eb48349da8`, LFM2-350M-Q4_0 `8fdc9d526b7ed346b19257551b05816c7912ecc2`, and pinned LFM2.5 audio `d78ca1db4adae8be7a7dbab003d128abdb5b94c6`. Sizes/SHA are verified; weights are external and never shipped. Native results are synthetic, without user prompts or credentials. Full failed/original logs and scratch consumers remain in the local evidence archive.

This does not certify NPU, every architecture/model, human listening quality, live-account effects or unrelated whole-SDK production gates. Prior published tags remain immutable. Post-publication exact-version resolution is verified separately.
