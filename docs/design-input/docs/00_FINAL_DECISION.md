# 00 — Final Decision

## 1. 질문에 대한 답

> iOS 27 미만에서도 `LanguageModel`, `LanguageModelSession`과 비슷한 contract를 제공하면 하위 호환성이 좋아지는가?

**그렇다. 단, Apple API를 그대로 복제하는 것과 Apple의 구조를 우리 공통 contract에 흡수하는 것은 구분해야 한다.**

정확한 방향은 다음이다.

```text
Apple API를 복제해서 Core로 사용      X
Apple 의미 구조를 Core contract로 수용 O
Apple-shaped source compatibility     선택 façade
Apple 실제 FoundationModels           iOS 27+ bridge
```

참고로 Apple에서 `LanguageModel`과 `LanguageModelExecutor`는 protocol이고, `LanguageModelSession`은 session class다.

## 2. 왜 타당한가

Apple의 iOS 27 Foundation Models 구조는 다음 책임 분리를 공식화했다.

```text
LanguageModel
  = 가벼운 모델 descriptor + capabilities + executor configuration

LanguageModelExecutor
  = 실제 local/server inference 실행

LanguageModelSession
  = transcript/context/tool/generation session
```

이 구조는 NativeAI가 이미 추구하는 `Policy / Mechanism`, provider 분리, runtime lifetime 분리와 잘 맞는다.

또한 실제 오픈소스에서 이미 검증되고 있다.

- Hugging Face `AnyLanguageModel`은 iOS 17+에서 Apple Foundation Models와 유사한 API를 제공한다.
- MLX의 `MLXFoundationModels`는 iOS 27에서 `FoundationModels.LanguageModel` conformance를 제공한다.
- Apple `coreai-models`의 `CoreAILanguageModel`도 `LanguageModel + LanguageModelExecutor`로 구현된다.
- Apple `foundation-models-utilities`는 hosted Chat Completions 모델을 `LanguageModelSession`에 넣는 `ChatCompletionsLanguageModel`을 제공한다.

즉 **하나의 model/session API로 local·server backend를 수렴시키는 방향 자체는 충분히 검증됐다.**

## 3. 하지만 그대로 복제하면 안 되는 이유

### 3.1 Apple API가 아직 움직인다

iOS 27의 `LanguageModel`, `LanguageModelExecutor` 계열은 현재 Apple 문서에서 Beta로 표시된다. exact clone을 public contract로 고정하면 Apple 변화가 곧 우리 breaking change가 된다.

### 3.2 같은 symbol 이름 충돌

우리 module과 `FoundationModels`를 동시에 import하면 `LanguageModel`, `LanguageModelSession` 같은 이름이 모호해질 수 있다.

따라서 exact-name API는 core가 아니라 **별도 compatibility module**에 한정하는 편이 안전하다.

### 3.3 `canImport`는 OS runtime 선택이 아니다

Xcode 27 SDK로 빌드하면 deployment target이 iOS 17이어도 `FoundationModels` module 자체는 컴파일 환경에 존재할 수 있다. 따라서:

```swift
#if canImport(FoundationModels)
```

만으로 iOS 17–26 runtime을 해결할 수 없다. runtime availability와 compile-time module availability는 다른 문제다.

### 3.4 Session authority 중복 위험

NativeAgent는 durable agent execution, approval, effect journal을 소유한다. 별도의 Apple-like session이 Agent lifecycle까지 소유하면 authority가 겹친다.

따라서:

```text
NativeAgent session != Language model session
```

을 명시적으로 유지해야 한다.

## 4. 최종 결정

### Accepted

1. `ModelCore`를 Apple 구조와 semantic alignment한다.
2. iOS 17+ 공통 contract를 `LanguageModel` / `LanguageModelExecutor` 개념으로 재정의한다.
3. 실행 owner는 `LanguageModelRuntime` 하나로 둔다.
4. Apple-like `LanguageModelSession` API가 필요한 경우 별도 `NativeLanguageModels` façade를 제공한다.
5. iOS 27+ 실제 Apple 모델은 `FoundationModelsBridge`로 연결한다.
6. NativeAgent는 core/runtime만 의존한다.

### Rejected

- `FoundationModels` module 자체를 재구현하는 것
- runtime OS에 따라 public typealias를 바꾸는 설계
- Agent 내부에서 iOS 버전으로 provider를 선택하는 것
- Apple session과 자체 session을 동시에 authoritative state owner로 사용하는 것
- AnyLanguageModel을 NativeAI 전체 모델 계층의 SSOT로 채택하는 것

## 5. 최종 제품 분류

| 영역 | 제품 | 역할 |
|---|---|---|
| Agent | `NativeAgent` | durable execution / approval / tools / recovery |
| Model Contract | `LanguageModelCore` | vendor-neutral model/executor contract |
| Model Runtime | `LanguageModelRuntime` | invocation/session/executor lifecycle |
| Compatibility | `NativeLanguageModels` | optional Apple-shaped developer façade |
| Apple Bridge | `FoundationModelsBridge` | iOS 27+ Apple `LanguageModel` interoperability |
| Apple 26 | `AppleSystemModelProvider` | iOS 26 SystemLanguageModel direct adapter |
| Local Provider | `MLXProvider` | MLX inference |
| Local Provider | `LiteRTProvider` | LiteRT inference |
| Local Provider | `LEAPProvider` | LEAP inference |
| Remote Provider | `ChatGPTTextProvider` | ChatGPT subscription text backend |
| Image | `ChatGPTImage` | independent image generation/edit service |
| Knowledge | `ASK` | canonical knowledge/evidence authority |
| Agent Tool Adapter | `ASKAgentTools` | Agent ↔ ASK optional tool projection |

## 6. 한 문장 아키텍처

> **NativeAgent는 실행을 소유하고, LanguageModel 계층은 모델 실행을 소유하며, Provider는 backend를 소유하고, ASK는 지식을 소유하며, Host가 이들을 조립한다.**
