# Apple 모델 adapter 경계 — ANALYSIS

## Verdict·책임 경계

**방향 MAINTAIN, native gate IMPROVE. 확신도 중간/낮음: public common projection 확인, SDK 27 typecheck 미실행.** 서로 다른 두 Apple-facing adapter를 같은 vendor 경계 분석에 포함하지만 같은 구현이라고 합치지 않는다. `AppleSystemModelProvider`는 기존 provider connector이고 `FoundationModelsBridge`는 SDK 27 model→공통 LanguageModel projection이다. NativeLanguageModels façade와도 별개다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| 기존 Apple provider 등록 | host → FoundationModelsProviderConnector | OS/framework availability, model descriptor | connector / native client | availability, runtime | [FoundationModelsProviderConnector.swift](../../Providers/AppleSystemModel/Sources/AppleSystemModelProvider/FoundationModelsProviderConnector.swift) |
| 기존 owned generation | Runtime → FoundationModelsClient | 공통 request와 native adapter 계약 | native invocation operation | events/cancel/completion | [FoundationModelsClient.swift](../../Providers/AppleSystemModel/Sources/AppleSystemModelProvider/FoundationModelsClient.swift) |
| SDK 27 projection | host → FoundationLanguageModel executor | canImport module version + OS availability; text-only | 호출별 native LanguageModelSession | text response / mapped native failure | [FoundationLanguageModel.swift](Sources/FoundationModelsBridge/FoundationLanguageModel.swift) |

## 실제 흐름

`host가 Apple model 선택 → bridge descriptor → ModelRuntime → executor → leading instructions/history + final user 투영 → native session respond await → common response`. bridge는 독립 Task를 만들지 않는다. 중간 system role을 임의 재배열하거나 maxOutputBytes를 추정 token 수로 환산하지 않는다. tools/media/structured를 지원한다고 광고하지 않는다.

## 현재 state·contract·I/O owner

native framework가 실제 inference를 소유하고 공통 Runtime은 admission/drain 계약을 소유한다. native error의 category/type/underlyingError를 보존하는 adapter만 둔다. system-model availability는 host OS/model 조건이며 패키지가 보장하는 고정 상수가 아니다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| 기존 provider common adapter 계약 | PUBLIC_LIBRARY | SATISFIED | PASS — 10 common tests; native 본문 제외 | [FoundationModelsClient.swift](../../Providers/AppleSystemModel/Sources/AppleSystemModelProvider/FoundationModelsClient.swift) |
| SDK 27 text bridge | PUBLIC_LIBRARY | UNKNOWN | NOT_RUN — native SDK signature/link/response | [FoundationLanguageModel.swift](Sources/FoundationModelsBridge/FoundationLanguageModel.swift) |
| structured/macros/audio parity | ABSENT_IN_SCOPE | NOT_IMPLEMENTED | N/A — 현재 text bridge 비목표 | [API.md](../../docs/API.md) |

## 실패·취소·복구 / findings

**F09 / 미검증.** source에 조건부 compilation과 availability가 있다고 설치 SDK에서 API가 맞는 것은 아니다. native symbols가 Linux compilation에서 제외되는 성공은 qualification으로 세지 않는다.

**CONFLICT 방지:** 이 단방향 text bridge를 AppleLocalAISession 전체 대체로 기록하면 보존된 structured/audio/profile 계약이 사라진다. 이전 보관 API는 사용자의 명시적 폐기 요청으로 제거했으며 이 bridge의 기능 동등성을 뜻하지 않는다. 이번 검토는 OS/API version을 새로 확정하지 않았다.

## Gap·검증·근거

27 native compile/link, 실제 iPhone/macOS availability/취소/stream 응답을 확인해야 한다. 외부 docs URL은 참고이며 installed SDK가 우선한다. 출처·날짜는 [RESEARCH.md](../../docs/RESEARCH.md)에 별도로 기록한다.
