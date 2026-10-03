# NativeAI Final Architecture — 2026-09-20

이 패키지는 기존 `NativeAgent / AppleLocalAI / ASK / Providers` 재분류안과, iOS 17–26에서도 Apple Foundation Models와 유사한 모델 계약을 제공하는 하위 호환 전략을 통합한 최종 설계 문서다.

## 최종 결론

1. `NativeAgent`는 **iOS 17+ provider-independent Agent execution SDK**다.
2. `ASK`는 **독립 Knowledge Authority**다.
3. 모델 계층은 iOS 17+에서 **Apple의 `LanguageModel → LanguageModelExecutor → Session` 의미 구조와 정렬**한다.
4. iOS 17–26에 Apple API를 그대로 위조하는 것이 아니라, **우리의 안정된 공통 contract를 Apple 구조와 semantic parity로 설계**한다.
5. Apple API와 같은 개발 경험이 필요한 경우에만 `NativeLanguageModels`라는 **선택 compatibility façade**를 둔다.
6. iOS 27+에서는 Apple의 실제 `FoundationModels.LanguageModel`을 `FoundationModelsBridge`로 수용한다.
7. NativeAgent는 `FoundationModels`, MLX, LiteRT, LEAP, ChatGPT를 직접 알지 않는다.
8. 별도 top-level `Integration` runtime/state owner는 만들지 않는다. 작은 protocol/tool adapter만 각 owner 가까이에 둔다.
9. Text reasoning provider와 Image capability는 분리한다.
10. Provider 선택과 OS availability는 Host policy다. 자동 fallback은 금지한다.

## 핵심 구조

```text
Host App
│
├─ NativeAgent ────────────────┐
├─ ASK                         │
└─ Provider Selection          │
   │                           │
   ▼                           │
LanguageModelRuntime <─────────┘
   │
   ├─ MLX / LiteRT / LEAP                iOS 17+
   ├─ ChatGPT Text                       iOS 17+
   ├─ AppleSystemModelAdapter            iOS 26+
   └─ FoundationModelsBridge             iOS 27+
       └─ any FoundationModels.LanguageModel

Optional API façade
NativeLanguageModels (iOS 17+)
└─ Apple-shaped LanguageModelSession-style developer API

Capabilities
├─ ASKAgentTools -> ASK
└─ ChatGPTImageCapability -> ChatGPTImage
```

## 문서

- `docs/00_FINAL_DECISION.md` — 최종 판단과 비판적 리뷰
- `docs/01_CURRENT_AND_TARGET.md` — 현재 구조와 목표 구조
- `docs/02_COMPATIBILITY_STRATEGY.md` — iOS 17–26 Apple-shaped 호환 전략
- `docs/03_PROTOCOL_SPEC.md` — 공통 모델 contract 상세
- `docs/04_PACKAGE_BOUNDARIES.md` — MECE package ownership
- `docs/05_OS_PROVIDER_MATRIX.md` — OS / provider / API matrix
- `docs/06_DEPENDENCY_RULES.md` — 허용·금지 dependency
- `docs/07_MIGRATION_PLAN.md` — clean-break migration
- `docs/08_VERIFICATION_PLAN.md` — build/runtime/API parity 검증
- `docs/09_RISKS_AND_NON_GOALS.md` — 위험과 비목표
- `docs/decisions/ADR-004-apple-aligned-model-contract.md`
- `docs/decisions/ADR-005-compatibility-facade-not-authority.md`
- `docs/research/2026-09-20-foundation-models-compat.md`

## Status

이 문서는 **설계 정본 제안**이다. 실제 source migration은 수행하지 않았다.
