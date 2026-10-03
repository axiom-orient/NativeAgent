# ChatGPTText

ChatGPT 계정 기반 Text service SDK입니다. `ChatGPTTextSession`이 catalog/model selection/quota를, `ChatGPTModelClient`가 ModelCore request·SSE·tool proposal·structured output을 소유합니다. Image와 Agent kernel에는 의존하지 않습니다.

```swift
import ChatGPTAccount
import LanguageModelCore
import ChatGPTText

// account는 host가 로그인한 공통 ChatGPTAccountSession입니다.
let text = ChatGPTTextSession(account: account)
let models = try await text.models()
let limits = try await text.rateLimits()
let client = try ChatGPTModelClient(text: text)
// request는 호출자가 만든 유효한 ModelRequest입니다.
let turn = try await client.generate(request: request)
```

`ChatGPTModelClient(account:...)` convenience도 제공합니다. metadata를 재사용할 때는 같은 TextSession을 공유합니다. account epoch가 달라진 cache는 사용하지 않습니다. exact model이 catalog에 없으면 모델을 바꾸지 않고 실패합니다.

`stream`은 validated ModelRequest → started → delta/tool events → completed → EOF 또는 오류입니다. ToolCall은 실행 제안이며 직접 tool I/O를 수행하지 않습니다. Agent 사용은 [Text adapter](../TextProvider/README.md)를 통합니다. 명시 취소·HTTP 오류·잘린 SSE·응답 한도를 성공으로 숨기지 않습니다. 재인증 retry는 기존 bounded policy를 따르며 Image/다른 provider로 fallback하지 않습니다.

[manifest](Package.swift) · [Agent Current](../../../Agent/NativeAgentPackage/docs/IMPLEMENTATION_STATUS.md) · [ModelCore 계약](../../../Model/LanguageModelCore/Sources/LanguageModelCore) · [검증](../../../docs/verification/README.md). 전체 Apple client/실계정 E2E는 NOT_RUN입니다.

## 완료를 소유하는 스트림 소비

`generate`는 owned completion까지 기다린다. `stream`은 기존 event projection이다. 조기 종료·명시적 취소·재사용 경계를 관리할 때는 다음 API를 사용한다.

```swift
func consume(
  client: ChatGPTModelClient, request: ModelRequest,
  receive: @Sendable (ModelEvent) -> Void
) async throws {
  let invocation = client.invocation(request: request, onStarted: {})
  try await withTaskCancellationHandler {
    let reading: Result<Void, any Error>
    do {
      for try await event in invocation.events { receive(event) }
      reading = .success(())
    } catch {
      invocation.cancel()
      reading = .failure(error)
    }
    // 실패한 receipt를 다시 기다려 성공으로 바꾸지 않는다.
    try await invocation.waitForCompletion()
    try Task.checkCancellation()
    try reading.get()
  } onCancel: {
    invocation.cancel()
  }
}
```

`completed` event나 EOF만으로 native/remote 종료를 추론하지 않는다. cancel은 idempotent signal이고 wait는 이미 취소된 caller도 기다릴 수 있다. drain 실패를 무시하고 runtime을 재사용하지 않는다. custom transport는 Account README의 invocation 계약을 구현해야 한다.

## Qualification 상태

계정·catalog 준비 단계의 transport 종료 실패도 producer task의 실패로 전파한다. event stream에 오류가 나왔다는 사실만으로 완료 성공을 보고하지 않는다. `ModelExecutorDrainFailure`는 실패한 invocation을 보존하며 Runtime은 이를 quarantine한다. 실제 Account/Text manifest의 Linux contract 테스트와 실계정 서비스 테스트는 다르다. [최신 검토](../../../docs/production/IMPLEMENTATION_REVIEW.md)를 따른다.
