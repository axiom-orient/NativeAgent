# AppleLocalAI — Architecture

## Layers

```text
Host
└─ AppleLocalAI
   ├─ AppleLocalAICore
   │  ├─ prompt normalization
   │  ├─ history window rules
   │  └─ operation lifecycle
   └─ AppleLocalAI session
      ├─ profile / request projection
      ├─ Foundation Models session
      └─ cancellation / late-result control

Optional packages
├─ AppleLocalAILocalModels → CoreAI / MLX / LiteRT
├─ AppleLocalAILEAP       → shared LeapSDK binary
└─ NativeAgentProviderAppleLocalAI → borrowed NativeAgent runtime adapter
```

Root package가 optional packages를 역으로 import하지 않는다.

## State ownership

| Concern | Owner |
|---|---|
| prompt/history pure rules | `AppleLocalAICore` |
| active session operation | `OperationController` / `AppleLocalAISession` |
| transcript | underlying `LanguageModelSession` |
| selected model | host/profile |
| vendor model resident | selected vendor runtime 또는 external host |
| shared NativeAgent resident | workspace `LocalBackend` |

## Operation flow

```text
AppleLocalAIRequest
→ validate/normalize
→ reserve operation
→ Foundation Models request
→ stream/response
→ operation identity check
→ settle once
→ snapshot/output
```

`cancel()`은 active task/native model에 취소를 전달하지만 이미 시작된 native 작업이 실제 종료됐다는 증거는 아니다. session state는 늦은 completion을 검증한 뒤 한 번만 settle한다.

## Shared NativeAgent composition

Shared runtime 사용 시 AppleLocalAI root가 model을 다시 load하지 않는다. `AppleLocalAI/Packages/NativeAgentProviderAppleLocalAI`가 host-owned `ModelRuntime`을 Apple `LanguageModel`로 projection한다. 상세 owner는 workspace [`ARCHITECTURE`](../../../docs/ARCHITECTURE.md)가 소유한다.
