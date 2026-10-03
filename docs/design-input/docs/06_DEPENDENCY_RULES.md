# 06 — Dependency Rules

## Allowed

```text
NativeAgent -> LanguageModelCore
NativeAgent -> LanguageModelRuntime
LanguageModelRuntime -> LanguageModelCore
NativeLanguageModels -> LanguageModelCore + LanguageModelRuntime
FoundationModelsBridge -> LanguageModelCore + FoundationModels
AppleSystemModelProvider -> LanguageModelCore + FoundationModels
MLXProvider -> LanguageModelCore + MLX
LiteRTProvider -> LanguageModelCore + LiteRT
LEAPProvider -> LanguageModelCore + LEAP
ChatGPTTextProvider -> LanguageModelCore + ChatGPTAccount
ChatGPTImage -> ChatGPTAccount
ASKAgentTools -> ASK + minimal NativeAgent Tool contract
Host -> all selected packages
```

## Forbidden

```text
LanguageModelCore -> NativeAgent
LanguageModelRuntime -> NativeAgent
Provider -> NativeAgentManager
Provider -> ASK
ASK root -> NativeAgent
NativeAgent kernel -> FoundationModels
NativeAgent kernel -> vendor SDK
Apple provider -> MLX + LiteRT + LEAP umbrella
Compatibility façade -> independent runtime authority
```

## Composition root

Host App이 최종 조립 owner다.

```swift
let model = selectedModel
let runtime = LanguageModelRuntime(model: model)

let agent = NativeAgent(
    modelRuntime: runtime,
    tools: [askTools, imageTools]
)
```

실제 API는 migration 후 source가 정본이다. 위 코드는 dependency direction만 나타낸다.
