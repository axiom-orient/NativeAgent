# 08 — Verification Plan

## 1. Build matrix

최소 실제 Apple toolchain에서 확인:

```text
iOS 17 deployment target
- NativeAgent + MLX or selected legacy provider
- NativeLanguageModels basic session

iOS 26 deployment target
- AppleSystemModelProvider
- direct providers

iOS 27 deployment target
- FoundationModelsBridge + SystemLanguageModel
- FoundationModelsBridge + CoreAILanguageModel
- FoundationModelsBridge + MLXLanguageModel
```

## 2. Contract tests

### LanguageModel

- capabilities truthful
- configuration stable/hashable
- descriptor immutable semantics

### Executor

- same configuration reuse
- different configuration isolation
- prewarm does not mutate Agent state
- response stream closes exactly once

### Runtime

- concurrent request rejection or explicit serialization
- cancellation propagates
- late success ignored after cancellation
- producer tasks drained
- close is idempotent

## 3. API parity tests

`NativeLanguageModels`가 source-shape parity를 표방하는 경우에만 수행한다.

- symbol graph snapshot
- sample code compile tests
- response/stream API signature comparison
- tool calling compile examples
- error mapping table

**Apple API 전체 parity를 테스트하지 않았다면 “drop-in replacement”라고 문서화하지 않는다.**

## 4. Provider qualification

Provider별로 build와 real inference를 분리 기록한다.

```text
BUILD_PASS
RUNTIME_PASS
SKIPPED_ENV
NOT_RUN
```

fake backend/mocks만으로 production capability를 검증했다고 보고하지 않는다.

## 5. ASK qualification

- grounded read returns evidence refs
- query has no hidden write
- mutation requires plan/dry-run/approval/apply
- duplicate apply idempotency

## 6. Image qualification

- text provider 선택과 image provider 선택 독립
- generate/edit artifact publication
- cancellation/failure evidence
- no false success
