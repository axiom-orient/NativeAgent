# 07 — Migration Plan

## P0 — Baseline freeze

- source archive + SHA-256
- all `Package.swift` graph snapshot
- public API/product snapshot
- current tests and qualification results

## P1 — Model contract extraction

이동:

```text
NativeAgentModelCore    -> Model/LanguageModelCore
NativeAgentModelRuntime -> Model/LanguageModelRuntime
```

동시에 기존 contract를 Apple-aligned semantics로 정리한다.

Acceptance:

- NativeAgent concrete provider import 0
- Provider NativeAgent import 0
- ModelCore vendor import 0

## P2 — Protocol reshape

기존 `ModelClient`/runtime contract를 한 번에 삭제하지 말고 mapping table을 만든다.

예:

```text
ModelClient             -> LanguageModel + Executor projection
ModelProviderRegistry   -> Host provider registry
ModelRequest/Event      -> Core request/event 유지 또는 rename
```

clean-break를 한다면 이 단계에서 public rename을 한 번만 한다.

## P3 — Direct provider migration

- MLX
- LiteRT
- LEAP
- ChatGPT Text

각 provider를 독립 package로 이동하고 새 core protocol conformance를 구현한다.

## P4 — Apple iOS 26

기존 SystemLanguageModel direct adapter를 `AppleSystemModelProvider`로 이동한다.

## P5 — iOS 27 Foundation Models bridge

`FoundationModelsBridge` 구현:

```text
Apple LanguageModel
→ capability mapping
→ transcript/request mapping
→ Apple session/executor call
→ NativeAI event stream
```

Apple model lifecycle과 NativeAI runtime lifecycle의 owner를 문서와 테스트로 고정한다.

## P6 — Compatibility façade

실제 제품 요구가 있을 때 `NativeLanguageModels`를 추가한다.

우선 범위:

1. basic `LanguageModelSession`
2. text response
3. streaming
4. generation options
5. tool calling

`@Generable` 완전 호환은 별도 milestone로 둔다.

## P7 — ASK / Image composition

- `ASKAgentTools`
- `ChatGPTImageCapability`

둘 다 optional adapter로만 유지한다.

## P8 — Remove legacy

모든 consumer migration과 qualification 이후에만 제거한다.

- AppleLocalAISession duplicate owner
- NativeAgent concrete providers
- vendor umbrella package
- cross-root relative dependencies
- obsolete integration examples

## Migration invariant

각 단계에서:

```text
old behavior verified
→ new path implemented
→ equivalence/intentional difference verified
→ consumer migrated
→ old path removed
```

순서를 지킨다.
