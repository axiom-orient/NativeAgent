# 04 — Package Boundaries

## 1. NativeAgent

**Owns**

- Agent session identity
- durable state transition
- approval
- tools/effects
- recovery
- effect journal
- skills

**Imports**

- `LanguageModelCore`
- `LanguageModelRuntime`

**Must not import**

- FoundationModels
- MLX / LiteRT / LEAP
- ChatGPT transport
- ASK root implementation

## 2. LanguageModelCore

**Owns**

- `LanguageModel`
- `LanguageModelExecutor`
- capabilities
- request/event/transcript primitives
- domain error taxonomy

**Must not import**

- NativeAgent
- ASK
- FoundationModels
- provider SDK

## 3. LanguageModelRuntime

**Owns**

- executor store
- invocation/session mechanism
- cancellation/drain
- stream validation

**Depends on**

- `LanguageModelCore`

## 4. NativeLanguageModels

Optional developer façade.

**Owns**

- Apple-shaped session convenience
- source-friendly Prompt/Response APIs
- optional Tool/structured-generation conveniences

**Does not own**

- a second executor runtime
- Agent state
- provider selection

## 5. FoundationModelsBridge

**Platform**: iOS/macOS/visionOS 27+

**Owns**

- Apple `FoundationModels.LanguageModel` → NativeAI contract projection
- capabilities/options/transcript mapping
- Apple error mapping

**Does not own**

- second session authority
- model downloads
- NativeAgent

## 6. AppleSystemModelProvider

**Platform**: iOS 26+

SystemLanguageModel의 iOS 26 direct integration을 보존한다.

iOS 27에서는 FoundationModelsBridge 경로와 중복될 수 있으므로 Host가 하나만 선택한다.

## 7. MLX / LiteRT / LEAP

각 provider는 자기 SDK만 소유한다.

```text
MLXProvider    -> MLX
LiteRTProvider -> LiteRT
LEAPProvider   -> LEAP
```

금지:

```text
LocalModels -> MLX + LiteRT + LEAP
```

## 8. ChatGPT

### Account

- login
- token/credential
- refresh/sign-out

### Text

- text model transport
- model/executor implementation

### Image

- image generate/edit
- binary artifact contract

Text와 Image는 runtime을 공유할 필요가 없다.

## 9. ASK

**Owns**

- source/version
- evidence
- canonical knowledge
- patch/decision/receipt
- journal/index/freshness

NativeAgent는 ASK를 knowledge DB로 복제하지 않는다.

## 10. ASKAgentTools

Optional adapter.

- read tool → ASK query
- write tool → plan/dryRun/approval/apply

이 package는 integration runtime이 아니라 contract projection이다.
