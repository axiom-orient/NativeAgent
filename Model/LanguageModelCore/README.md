# LanguageModelCore

외부 package/vendor/Agent dependency가 없는 stable model contract.
`LanguageModel` + `LanguageModelExecutor`, `ModelDescriptor`/capabilities,
기존 `ModelRequest`/`ModelEvent`/`ModelTurn`/`AgentMessage`와 검증 규칙을 소유한다.

`ModelTextRequest`는 text-only exact request projection,
`ModelTextSnapshotAccumulator`는 UTF-8 cumulative snapshot 검증이다.
SDK/계정/실제 inference는 이 package 밖에 둔다.
기존 공개 stream/deadline utility는 계약 보존을 위해 유지했으며 module 전체가 부수효과 없는 함수만 가진다는 뜻은 아니다.

기존 client를 감싸는 `ClientLanguageModel`은 mechanism 경계인 형제 Runtime에 있다.
새 schema/typealias 사본을 만들어 Core와 의미를 중복 소유하지 않는다.

```sh
swift test -Xswiftc -warnings-as-errors
```

[전체 계약](../../docs/SPEC.md) · [검증](../../docs/verification/README.md)

ModelClient는 generate와 stream을 모두 명시적으로 구현해야 한다. generate-only 기본 stream 구현은 제공하지 않는다.
