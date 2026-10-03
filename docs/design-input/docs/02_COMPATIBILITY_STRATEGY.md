# 02 — iOS 17–26 Compatibility Strategy

## 1. 목적

목표는 Apple Foundation Models를 흉내내는 것이 아니다.

목표는 다음 세 가지다.

1. iOS 17–26에서도 provider를 같은 개념으로 교체할 수 있다.
2. iOS 27로 올라가도 mental model과 provider 구현을 크게 다시 쓰지 않는다.
3. NativeAgent는 OS/vendor API와 무관하게 같은 model contract를 사용한다.

## 2. 3계층 전략

### Layer A — Stable Core Contract

`LanguageModelCore` — iOS 17+

Apple 구조와 의미를 맞추되 NativeAI가 소유하는 안정된 contract다.

```text
LanguageModel
LanguageModelExecutor
LanguageModelCapabilities
ModelGenerationRequest
ModelGenerationEvent
ModelTranscript
```

여기에는 `FoundationModels` import가 없다.

### Layer B — Runtime

`LanguageModelRuntime` — iOS 17+

- executor store
- invocation admission
- cancellation
- stream terminal validation
- drain/join
- transcript/session mechanism

NativeAgent는 이 계층까지만 사용한다.

### Layer C — Optional Apple-shaped Façade

`NativeLanguageModels` — iOS 17+

독립 앱이나 provider 실험에서 Apple과 유사한 개발 경험이 필요할 때 사용한다.

예:

```swift
import NativeLanguageModels

let model = MLXLanguageModel(...)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "...")
```

이 façade는 `LanguageModelRuntime`을 감쌀 뿐 별도 lifecycle authority를 만들지 않는다.

## 3. 왜 core와 façade를 분리하는가

### Core

- 장기 안정성
- Agent에서 필요한 정확한 contract만 유지
- Apple beta API 변화에 직접 노출되지 않음

### Façade

- 개발자 source compatibility
- Apple mental model과 유사
- 필요하면 deprecation/rename 가능
- exact parity 범위를 명시할 수 있음

## 4. Exact parity 수준

호환성을 3단계로 명시한다.

### Level 1 — Concept parity — Required

반드시 맞춘다.

- Model은 lightweight descriptor
- Model은 capabilities 제공
- Model은 executor configuration 제공
- Executor configuration은 `Hashable + Sendable`
- Executor가 실제 inference 수행
- Session이 conversation/request context를 소유
- capability 미지원은 dispatch 전에 명시적 실패

### Level 2 — Source-shape parity — Recommended

가능한 범위에서 맞춘다.

- `LanguageModel`
- `LanguageModelExecutor`
- `LanguageModelSession`
- `LanguageModelCapabilities`
- `GenerationOptions`
- streaming response
- Tool calling surface

### Level 3 — Drop-in parity — Not guaranteed

다음은 자동으로 약속하지 않는다.

- 모든 Foundation Models macro
- 모든 `@Generable`, `@Guide` 동작
- Apple private/internal prompt encoding
- 모든 error case의 1:1 mapping
- Apple Instruments behavior
- Apple session caching semantics

Drop-in을 공식 지원하려면 별도 API parity test와 문서가 필요하다.

## 5. iOS 27 bridge

```text
FoundationModels.LanguageModel
          │
          ▼
FoundationModelsBridge
          │
          ▼
LanguageModelCore/Runtime
```

bridge는 Apple model을 NativeAI model contract로 투영한다.

반대 방향:

```text
NativeAI LanguageModel
        ↓ optional
FoundationModels.LanguageModel adapter
```

은 실제 consumer가 생길 때만 제공한다. 왕복 bridge를 기본 경로로 만들지 않는다.

## 6. iOS 26

iOS 26에는 `SystemLanguageModel`을 직접 사용할 수 있으므로 기존 direct adapter를 `AppleSystemModelProvider`로 유지한다.

iOS 27 migration 때문에 iOS 26 Apple system model 경로를 버리지 않는다.

## 7. AnyLanguageModel 검토

Hugging Face `AnyLanguageModel`은 이 전략의 실현 가능성을 보여주는 좋은 reference다.

장점:

- iOS 17+
- Apple-like `LanguageModelSession`
- MLX/CoreML/llama.cpp/cloud provider 지원
- FoundationModels conformer wrapping

그러나 NativeAI core dependency로 채택하지 않는다.

이유:

- 현재 pre-1.0
- 외부 public contract에 core architecture가 종속됨
- Xcode/구버전 deployment 관련 알려진 호환 이슈가 문서화되어 있음
- SwiftPM traits 관련 dependency-resolution workaround가 필요할 수 있음
- NativeAgent에는 이미 별도의 durable execution semantics가 있음

권장 사용:

```text
Reference implementation    O
Compatibility oracle       O
Optional experimental adapter O
NativeAI SSOT              X
```

## 8. 핵심 결론

> **하위 호환을 위해 Apple API와 같은 “모양”은 유용하지만, NativeAI의 정본은 Apple API 복제품이 아니라 Apple과 정렬된 독립 contract여야 한다.**
