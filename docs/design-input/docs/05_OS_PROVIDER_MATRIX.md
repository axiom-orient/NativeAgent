# 05 — OS / Provider Matrix

## 1. Capability matrix

| OS | Common Core | Native façade | Apple System | Apple generic LanguageModel | Direct local | ChatGPT |
|---|---|---|---|---|---|---|
| iOS 17–25 | O | O | X | X | MLX/LiteRT/LEAP | O |
| iOS 26 | O | O | O | X | MLX/LiteRT/LEAP | O |
| iOS 27+ | O | O | O | O | MLX/LiteRT/LEAP | O |

`Native façade`는 `NativeLanguageModels`를 뜻한다.

## 2. Recommended default by OS

이 표는 자동 fallback 순서가 아니라 **Host가 선택 가능한 기본 후보**다.

### iOS 17–25

```text
Local preferred  -> selected direct local provider
Remote preferred -> ChatGPT Text
```

### iOS 26

```text
Apple system model candidate
+ direct local providers
+ ChatGPT Text
```

### iOS 27+

```text
FoundationModelsBridge(any Apple LanguageModel)
+ direct providers if explicitly selected
+ ChatGPT Text
```

## 3. iOS 27 generic Apple path

```text
SystemLanguageModel ──────────┐
PrivateCloudComputeLanguageModel
CoreAILanguageModel           ├─ FoundationModels.LanguageModel
MLXLanguageModel              │
ChatCompletionsLanguageModel ─┘
               ↓
      FoundationModelsBridge
               ↓
     LanguageModelRuntime
               ↓
          NativeAgent
```

## 4. Direct MLX on iOS 27

MLX 모델을 iOS 27에서 반드시 Apple bridge로만 써야 하는 것은 아니다.

두 경로 모두 가능하다.

```text
A. MLXProvider -> NativeAI Runtime
B. MLXLanguageModel -> FoundationModels -> NativeAI Bridge
```

Host가 하나를 명시적으로 선택한다.

같은 request를 A→B→A처럼 왕복시키지 않는다.

## 5. Provider pinning

Agent session이 실행을 시작한 뒤에는 다음을 pin한다.

```text
providerID
modelID
capability contract
transport contract
```

Provider 변경은 새 execution contract 또는 새 session으로 처리한다.
