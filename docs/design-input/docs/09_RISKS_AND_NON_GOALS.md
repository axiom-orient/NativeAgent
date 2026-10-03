# 09 — Risks and Non-Goals

## 1. Apple API drift

[KNOWN]

iOS 27 custom LanguageModel APIs는 현재 Beta 문서가 포함되어 있다.

대응:

- Apple exact API는 bridge/facade에 격리
- Core contract는 자체 semantic versioning
- Apple SDK update 시 bridge qualification

## 2. Exact compatibility maintenance cost

Apple `LanguageModelSession` 전체 surface를 추적하면 작은 provider abstraction 프로젝트가 framework clone으로 변할 수 있다.

따라서 default 목표는:

```text
concept parity > source-shape parity > full drop-in parity
```

## 3. AnyLanguageModel dependency risk

좋은 reference지만 core SSOT로 채택하면 외부 pre-1.0 package 변경, toolchain issue, provider policy가 NativeAI core에 전파된다.

따라서 기본은 직접 core ownership이다.

## 4. Symbol ambiguity

`FoundationModels`와 Apple-shaped compatibility module을 동시에 import할 때 동일 symbol 이름이 충돌할 수 있다.

대응:

- compatibility module을 optional product로 유지
- bridge 내부에서는 module qualification 사용
- public docs에서 동시에 import하는 pattern을 피함

## 5. Macro parity

`@Generable`, `@Guide` 등은 단순 protocol copy가 아니다.

[NON-GOAL — initial]

- Foundation Models macro 전체 재구현

필요 시 별도 package/macro target으로 추가한다.

## 6. Provider fallback

[NON-GOAL]

- invisible automatic fallback

Provider availability와 selection은 Host가 explicit policy로 결정한다.

## 7. Agent/Model session conflation

[NON-GOAL]

- model session이 Agent durable state를 소유하는 것
- Agent가 provider resident cache를 소유하는 것

## 8. Universal multimodal abstraction

현재 필요 이상의 universal AI service abstraction을 만들지 않는다.

- text/vision language model
- image generation
- knowledge
- Agent execution

을 각각 명확히 분리한다.
