# Research — Foundation Models Compatibility — 2026-09-20

## 1. Apple Foundation Models iOS 27

Apple은 2026 Foundation Models 업데이트에서 `LanguageModel` protocol을 통해 on-device 또는 server LLM을 Foundation Models framework에 연결할 수 있다고 설명한다.

`LanguageModel` required surface:

- capabilities
- executorConfiguration
- associated `Executor`

`LanguageModelExecutor` required surface:

- `Configuration: Hashable & Sendable`
- `init(configuration:)`
- `respond(... streamingInto:)`
- optional/default prewarm behavior

Apple WWDC26 설명에 따르면 configuration이 executor reuse의 핵심 연결점이다.

Sources:

- https://developer.apple.com/documentation/foundationmodels/languagemodel
- https://developer.apple.com/documentation/foundationmodels/languagemodelexecutor
- https://developer.apple.com/documentation/updates/foundationmodels
- https://developer.apple.com/videos/play/wwdc2026/339/

## 2. Apple Core AI

Apple `coreai-models`의 `CoreAILanguageModel`은 `FoundationModels.LanguageModel`을 구현하고 별도 `CoreAIExecutor`가 `LanguageModelExecutor`를 구현한다.

이 구현은 model descriptor / executor / resource control 분리가 실제 Apple open source에서도 사용된다는 근거다.

Source:

- https://github.com/apple/coreai-models

## 3. MLXFoundationModels

`ml-explore/mlx-swift-lm`은 iOS/macOS/visionOS 27 SDK에서 `MLXLanguageModel`을 `FoundationModels.LanguageModel` adapter로 제공한다.

중요한 설계점:

- 전체 MLX package는 iOS 17+를 지원
- FoundationModels adapter만 OS 27 SDK로 gate
- adapter를 package trait로 격리

Source:

- https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXFoundationModels

## 4. Apple foundation-models-utilities

Apple의 utilities package는 `ChatCompletionsLanguageModel`을 제공하여 hosted chat-completions compatible model을 `LanguageModelSession`에 연결한다.

이는 Foundation Models가 Apple system model 전용 abstraction이 아니라 server provider bridge로 확장되었다는 근거다.

Source:

- https://github.com/apple/foundation-models-utilities

## 5. Hugging Face AnyLanguageModel

`AnyLanguageModel`은 Apple Foundation Models API와 유사한 surface를 iOS 17+에서 제공한다.

Current documented characteristics observed on 2026-09-20:

- iOS 17+
- Apple-like `LanguageModelSession`
- CoreML / MLX / llama.cpp optional traits
- Apple Foundation Models conformer wrapping
- remote providers

이 프로젝트는 “Apple-shaped compatibility façade on older OS”가 현실적으로 가능하다는 강한 reference다.

하지만 core adoption에 대한 주의점도 문서화되어 있다.

- pre-1.0
- Xcode 26 + older deployment target 관련 build issue 안내
- package traits dependency resolution workaround 안내

Source:

- https://github.com/huggingface/AnyLanguageModel

## 6. ManifoldKit cautionary evidence

ManifoldKit은 과거 AnyLanguageModel bridge를 사용했으나 외부 pre-1.0 dependency coupling과 실제 adoption 문제를 이유로 제거했다고 문서화한다.

이 사례는 compatibility library를 참고하는 것과 core architecture를 외부 package에 위임하는 것을 구분해야 한다는 근거다.

Source:

- https://github.com/ManifoldKit/ManifoldKit

## 7. Architecture conclusion

Research evidence supports:

```text
Apple-aligned model/executor semantics   YES
Older-OS Apple-shaped façade             FEASIBLE
Exact framework clone as core            NO
External compatibility package as SSOT   NOT RECOMMENDED
OS-specific bridge isolation             YES
```
