# NativeAgentProviderAppleLocalAI

NativeAgent와 AppleLocalAI를 연결하는 **선택 adapter package**다. 새 Agent loop, DB, model loader, download service, HTTP/MCP gateway를 소유하지 않는다.

- Swift tools: **6.4**
- Platforms: **iOS 27+, macOS 27+**
- Dependencies: `LanguageModelCore`, `LanguageModelRuntime`, `AppleLocalAI`

## Shared direction

```text
Host LocalBackend
└─ same ModelRuntime
   ├─ NativeAgent → borrowed access
   └─ NativeRuntimeLanguageModel → Apple LanguageModelSession
```

```swift
let runtime = try await backend.load()
let model = NativeAgentProviderAppleLocalAI.makeLanguageModel(
  runtime: runtime,
  sessionID: "apple"
)
let session = try AppleLocalAISession(
  profile: try AppleLocalAIProfile(model: model)
)
```

Apple session/executor는 shared runtime을 load/unload하지 않는다. Host가 모든 consumer를 종료한 뒤 `backend.shutdown()`을 호출한다.

## Existing reverse adapter

기존 arbitrary Apple `LanguageModel` → operation-owned Native `ModelRuntime` factory도 보존한다. 이 경로와 shared Native runtime → Apple `LanguageModel` 경로를 재귀적으로 조합하지 않는다.

## Projection contract

Shared bridge는 현재 다음을 지원한다.

- text transcript.
- complete structured history의 JSON representation.
- runtime이 `structuredOutput` capability를 가진 경우 guided generation.

다음은 effect 전에 명시 거부한다.

- unsupported media/reasoning/tool transcript.
- enabled tools.
- arbitrary metadata.
- 현재 mapping하지 않는 explicit generation options.

Unknown token usage를 character/byte 수로 추정하지 않는다. Apple bridge가 final text를 emit하는 시점은 `ModelRuntime.generate`가 terminal과 provider/native drain을 만족한 뒤다.

## 검증

Portable binding/controller tests는 workspace `python3 tools/verify-portable.py`로 검사한다. Foundation Models API typecheck/link와 actual native inference는 Swift 6.4+/SDK 27 환경의 별도 gate다.

정본: [공유 아키텍처](../../../../docs/ARCHITECTURE.md) · [공유 계약](../../../../docs/SPEC.md) · [구현 상태](../../../../docs/IMPLEMENTATION_STATUS.md).
