# NativeAI Final Architecture

## Decision

NativeAI는 iOS 17+ 공통 모델 계층을 Apple iOS 27 Foundation Models의 `LanguageModel → LanguageModelExecutor → LanguageModelSession` 책임 분리와 **semantic alignment**한다.

그러나 Apple API 전체를 복제하지 않는다.

```text
Core contract                 = NativeAI-owned, iOS 17+
Runtime                       = NativeAI-owned, iOS 17+
Apple-shaped compatibility    = optional façade
Apple FoundationModels        = iOS 27+ bridge
NativeAgent                   = model runtime consumer
ASK                           = independent knowledge authority
```

## Final Structure

```text
NativeAI/
├── Agent/
│   └── NativeAgent/
│
├── Model/
│   ├── LanguageModelCore/
│   ├── LanguageModelRuntime/
│   ├── NativeLanguageModels/
│   ├── FoundationModelsBridge/
│   ├── ModelArtifactStore/
│   └── ModelHub/
│
├── Providers/
│   ├── AppleSystemModel/
│   ├── MLX/
│   ├── LiteRT/
│   ├── LEAP/
│   └── ChatGPT/
│       ├── Account/
│       ├── Text/
│       └── Image/
│
├── Knowledge/
│   └── ASK/
│       └── Packages/ASKAgentTools/
│
└── Qualification/
```

## Core Rules

1. NativeAgent는 provider를 모른다.
2. LanguageModelCore는 vendor SDK를 모른다.
3. Provider는 Agent를 모른다.
4. ASK는 Agent session을 소유하지 않는다.
5. Compatibility façade는 별도 runtime authority가 아니다.
6. iOS availability와 provider selection은 Host 정책이다.
7. Text reasoning과 image generation은 분리한다.
8. Integration runtime은 만들지 않는다.
9. Adapter는 owner 가까이에 둔다.
10. build success와 real inference success를 분리해 검증한다.

## Compatibility Decision

- `LanguageModel` / `LanguageModelExecutor` 개념은 core에 반영한다.
- Apple과 같은 이름/사용감을 제공하는 `LanguageModelSession`은 `NativeLanguageModels`에만 둔다.
- iOS 27에서는 `FoundationModelsBridge`가 Apple 실제 `LanguageModel`을 수용한다.
- AnyLanguageModel은 reference/compatibility oracle로 활용할 수 있으나 NativeAI core SSOT로 사용하지 않는다.

## Result

이 구조는 iOS 17에서 시작해 iOS 27의 Foundation Models 생태계로 올라갈 때 provider와 Agent를 재작성하지 않고, Apple API 변화도 bridge/facade에 격리한다.
