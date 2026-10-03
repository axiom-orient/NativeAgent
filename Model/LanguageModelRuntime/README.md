# LanguageModelRuntime

`LanguageModelRuntime`은 **한 model invocation의 admission/cancel/drain과 shared local backend lifetime contract**를 제공하는 독립 package다. `LanguageModelCore`만 의존하며 FoundationModels/vendor/UI/Agent orchestration을 의존하지 않는다.

## 두 owner를 구분한다

- `ModelRuntime`: invocation admission, reservation, cancellation, event validation, terminal/drain, runtime shutdown.
- `LocalBackend`: 한 host-selected backend configuration의 load와 final resident release.

```swift
let runtime = try await backend.load()
let connector = try await backend.providerConnector(displayName: "Selected model")
let registry = try ModelProviderRegistry([connector])
let access = try await registry.acquireRuntime(
  .init(providerID: runtime.providerID, modelID: runtime.modelDescriptor.id)
)

defer { /* async scope에서 try await access.release() */ }
```

Shared connector는 `.borrowed(runtime)`을 반환한다. Legacy/operation-owned connector는 기본 `.owned(runtime)` semantics를 유지한다. Borrowed caller는 raw `runtime.shutdown()`으로 host lifetime을 탈취해서는 안 된다.

`LocalBackend.shutdown()`은 runtime drain을 먼저 join하고 그 다음 resident release를 수행한다. drain/release 실패는 successful close가 아니며 resources를 failed/quarantined 상태로 유지한다.

`ModelClientWithOwnedInvocation`은 buffered provider가 producer cancellation과 native completion을 runtime에 증명할 수 있게 하는 선택 contract다. stream EOF만으로 native drain 완료를 가정하지 않는다.

## 검증

```sh
swift test -Xswiftc -warnings-as-errors
```

이 테스트는 lifecycle contract를 검증하며 MLX/LEAP/LiteRT 실제 inference 증거가 아니다. Workspace 규범은 [`../../docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md)와 [`../../docs/SPEC.md`](../../docs/SPEC.md)를 따른다.

## Descriptor/executor 및 대화

`ClientLanguageModel(client:)`은 기존 exact-request client를 새 LanguageModel contract로 투영한다.
`ModelRuntime(id:model:)`은 기존 client 진입점과 같은 admission/drain authority를 사용한다.
`ModelExecutorStore`는 host 범위의 `(Executor.Type, Configuration)`별 runtime을 재사용한다.

`ModelSession`은 committed transcript와 자신의 delivery Task만 소유한다.
`SessionLedger.reduce`는 pure transition이며 성공·drain 이후 commit, 실패 rollback,
stale generation 차단, response metadata 보존 및 message ID 충돌 방지를 담당한다.
borrowed close는 다른 대화나 model resident를 종료하지 않는다.

`NativeLanguageModels`는 이 ModelSession을 전달하는 선택형 façade다. image/tool effect 실행은 여기에 없다.
