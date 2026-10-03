# 01 — Current and Target Architecture

## 1. 현재 구조에서 보존할 것

기존 분석에서 확인된 좋은 경계는 유지한다.

- NativeAgent: agent execution / approval / recovery
- ASK: 독립 canonical knowledge owner
- ChatGPT Account / Text / Image 분리
- provider-neutral model request/event/runtime 개념
- Host에서 provider selection 가능
- `externalKnowledgeBase`를 통한 ASK 외부 authority 수용

## 2. 현재 구조의 핵심 문제

### 2.1 Model contract가 Agent 폴더에 소속됨

현재 `NativeAgentModelCore`, `NativeAgentModelRuntime`가 NativeAgent 하위에 있어 provider가 Agent 구현 세부사항에 의존하는 모양이다.

### 2.2 AppleLocalAI 책임 과다

현재 AppleLocalAI가 다음을 동시에 소유한다.

- Foundation Models wrapper
- 자체 session
- operation lifecycle
- CoreAI/MLX/LiteRT/LEAP umbrella
- NativeAgent adapter

이것은 provider package라기보다 두 번째 runtime platform에 가깝다.

### 2.3 Cross-root production dependency

AppleLocalAI provider/LEAP package가 NativeAgent 내부 상대경로 package를 직접 참조한다. 폴더 이동이 build graph를 깨뜨리는 구조다.

## 3. 목표 repository layout

```text
NativeAI/
├── Agent/
│   └── NativeAgent/
│
├── Model/
│   ├── LanguageModelCore/
│   ├── LanguageModelRuntime/
│   ├── NativeLanguageModels/        # optional Apple-shaped API façade
│   ├── FoundationModelsBridge/      # iOS 27+
│   ├── ModelArtifactStore/
│   └── ModelHub/                    # optional
│
├── Providers/
│   ├── AppleSystemModel/            # iOS 26+
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
│       └── Packages/
│           └── ASKAgentTools/
│
└── Qualification/
```

상위 `NativeAI/`는 repository grouping일 뿐 하나의 giant Swift package가 아니다.

## 4. 목표 dependency graph

```text
                             Host App
                                │
            ┌───────────────────┼────────────────────┐
            │                   │                    │
            ▼                   ▼                    ▼
      NativeAgent              ASK           Provider Selection
            │                                        │
            └──────────────────┬─────────────────────┘
                               ▼
                    LanguageModelRuntime
                               │
                     LanguageModelCore
                               │
         ┌────────────┬────────┼──────────┬──────────────┐
         ▼            ▼        ▼          ▼              ▼
       MLX          LiteRT    LEAP     ChatGPT Text   Apple Bridge
                                                        iOS 27+

Optional façade:
NativeLanguageModels -> LanguageModelRuntime/Core

Capabilities:
ASKAgentTools -> ASK
ChatGPTImageCapability -> ChatGPTImage
```

## 5. Authority map

| Material state/resource | Owner |
|---|---|
| Agent durable state | NativeAgent |
| approval / effect journal | NativeAgent |
| model capability / request contract | LanguageModelCore |
| executor/session/invocation lifetime | LanguageModelRuntime |
| model credential / remote session | Provider |
| native weights / resident engine | Provider |
| provider selection / OS availability policy | Host |
| canonical source/evidence/knowledge | ASK |
| image artifact generation | Image provider |
| UI/settings/account choice | Host App |

## 6. Explicit execution flow

### Agent text request

```text
Input
→ NativeAgent decision
→ frozen ModelRequest
→ LanguageModelRuntime
→ selected LanguageModel/Executor
→ stream events
→ terminal validation/drain
→ NativeAgent commits durable result
→ Output
```

### ASK query

```text
Agent tool decision
→ ASKAgentTools
→ ASK.query
→ evidence-backed result
→ Agent continuation
```

### ASK mutation

```text
Agent proposal
→ ASK.plan
→ ASK.dryRun
→ explicit approval
→ ASK.apply
→ receipt
```

### Image

```text
Agent tool decision
→ ChatGPTImageCapability
→ ChatGPTImage
→ durable image artifact
→ Agent result
```
