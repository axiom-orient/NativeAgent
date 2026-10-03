# NativeLanguageModels

Runtime의 `ModelSession`을 감싸는 선택형 Apple-shaped API. FoundationModels drop-in이 아니다.

```swift
import LanguageModelRuntime
import NativeLanguageModels

// access는 host가 명시적으로 준비한 ModelRuntimeAccess다.
let session = LanguageModelSession(id: "conversation", runtime: access, instructions: "Be precise.")
let turn = try await session.respond(to: "Hello")
try await session.close()
```

실행 가능한 완전한 앱 예제가 아니라, 준비된 host runtime을 받는 사용 부분이다.
`close`는 owned/borrowed 계약을 따른다. 실패 경로도 host가 close/오류를 처리해야 한다.
model + ModelExecutorStore를 받는 initializer는 store runtime을 빌려 사용한다.

Options: tools, outputFormat, maxOutputBytes, deadline, limits.
`streamResponse`는 ModelEvent sequence이며 text-only provider에는 delta가 없을 수 있다.
ToolCall은 반환만 한다. actual effect·승인·loop는 Agent/host의 책임이다.

본 타입은 자체 mutable history/task/loader를 갖지 않는다. `@Generable`/`@Guide`/Apple generic response parity는 미지원이다.
[계약](../../docs/SPEC.md) · [검증](../../docs/verification/README.md)
