# LanguageModelCore — ANALYSIS

> Production refactor 현재 상태: [구현·리뷰](../../docs/production/IMPLEMENTATION_REVIEW.md), [검증](../../docs/production/QUALIFICATION.md). 기존 아래 baseline 수치/환경 관측과 최신 결과를 구분한다.

## Verdict·책임 경계

**방향 IMPROVE. 확신도 높음: 순수 계약과 재현한 변환 오류 범위.** caller는 Runtime, Agent domain, provider와 외부 Swift library consumer다. 가치는 공통 request/event/schema 의미를 하나로 유지하는 것이다. 이 단위는 대화 저장·provider 선택·네트워크·resident를 소유하지 않는다. `LanguageModel`은 descriptor/configuration, executor는 실행 port다. 기존 `ModelClient` port도 유지한다. 형식상의 protocol 수를 줄이기 위해 이행 중인 public port를 삭제할 근거는 없다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| JSON public library | wire/tool caller → JSONValue accessors/from(any:) | NSNumber/Int64/Double; 정확한 정수 변환 | 순수 value 변환 | JSONValue 또는 nil/throw | [JSONValue+Accessors.swift](Sources/LanguageModelCore/JSON/JSONValue+Accessors.swift); [JSONValue+Bridging.swift](Sources/LanguageModelCore/JSON/JSONValue+Bridging.swift) |
| generation contract | Runtime.reserve / registry / Hub → validateGenerationContract | descriptor, request limits, roles, schema | Core validator; 실행 권한 없음 | 유효값 또는 ModelGenerationFailure | [ModelGeneration.swift](Sources/LanguageModelCore/Contracts/ModelGeneration.swift) |
| model/executor port | 외부 descriptor → LanguageModelExecutor | Sendable configuration/request; completion 계약 | 구현체가 effect; Core는 요구만 정의 | event sink / failure / drain failure | [LanguageModel.swift](Sources/LanguageModelCore/Contracts/LanguageModel.swift) |
| explicit streaming port | ClientLanguageModel → ModelClient.stream | request와 client capability | provider가 스트림·실행 수명을 명시적으로 구현 | ModelEvent stream | [ModelClient.swift](Sources/LanguageModelCore/Contracts/ModelClient.swift) |
| owned invocation port | Runtime → cancel/waitForCompletion | 호출 identity와 완료 handle | provider가 실제 producer completion 소유 | 명시적 cancel/join 결과 | [ModelClientInvocation.swift](Sources/LanguageModelCore/Contracts/ModelClientInvocation.swift) |
| schema·stream contract | tool/stream caller → ToolSchema / ModelStreamContract | 값 크기·타입·event 순서 | 순수 schema/contract state | validation 또는 contract failure | [ModelStreamContract.swift](Sources/LanguageModelCore/Contracts/ModelStreamContract.swift); [ToolSchema.swift](Sources/LanguageModelCore/Schema/ToolSchema.swift) |

## 실제 흐름

`wire/host value → JSONValue → schema/request validation → Runtime가 허용한 effect`. Core 내부에서 DB/file/network effect로 연결되는 경로는 없다. `ModelClient.stream`은 provider의 필수 구현이다. generate-only 기본 stream 경로는 제거했다. 독립 producer/native 작업이 있으면 owned invocation의 cancel/waitForCompletion으로 drain을 증명한다.

## 현재 state·contract·I/O owner

`JSONValue`, `ModelRequest`, `ModelEvent`, `AgentMessage`, `LanguageModel` 계약이 정본이다. 구조 validation과 provider-specific availability/auth validation은 서로 다른 경계이므로 중복 제거 대상이 아니다. `ModelGenerationFailure`는 code와 최대 4096 UTF-8 bytes의 message로 정규화하며 `modelFailureDetails`는 빈 값이다. raw underlying error·provider details 전체를 보존하는 계약은 아니다. 처리 중인 대화 상태는 여기에 추가하지 않는다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| 공통 값·schema·generation 계약 | PUBLIC_LIBRARY | SATISFIED | PASS — 실제 Core 56 tests; provider I/O는 N/A | Tests/LanguageModelCoreTests |
| 숫자 bridge·정수 경계 | PUBLIC_LIBRARY | SATISFIED | PASS — 수정 전 trap/실패 및 신규 6 tests | [JSONNumericBoundaryTests.swift](Tests/LanguageModelCoreTests/JSONNumericBoundaryTests.swift) |
| UTF-8 진단 길이 제한 | PUBLIC_LIBRARY | SATISFIED | PASS — 신규 3 tests; 4096-byte 경계 | [FailureMessageBoundaryTests.swift](Tests/LanguageModelCoreTests/FailureMessageBoundaryTests.swift) |
| 구체 provider native settlement | ABSENT_IN_SCOPE | UNKNOWN | N/A — Core가 실행하지 않음 | [ModelClientInvocation.swift](Sources/LanguageModelCore/Contracts/ModelClientInvocation.swift) |

## 실패·취소·복구 / findings

**F01 / 수정.** `Double(Int.max)`가 반올림되어 범위 검사에 들어온 뒤 `Int(value)`에서 trap → 수정 전 SIGILL 재현 → 부정확한 부동소수 범위 검사 → 외부 숫자 입력으로 process 중단 → `Int(exactly:)`로 수렴했다.

**F02 / 수정.** `NSNumber(0/1)`이 Swift Bool bridge에 먼저 매치 → 2개 assertion 실패 → permissive Foundation bridging 순서 → tool/wire 숫자가 불리언으로 변형 → CFBoolean type identity를 먼저 검사한다. 진짜 Bool은 그대로 보존한다.

**F03 / 수정.** 4096 bytes에 정확히 맞는 UTF-8 문자까지 잘라 전체 진단이 fallback 문자열로 교체됨 → 2/3/4-byte 경계 재현 → continuation-byte만 보는 절단 → 원인 메시지 유실 → 유효한 UTF-8 prefix까지만 줄인다. public error 의미·한도는 바꾸지 않았다.

## Gap·검증·근거

새 테스트는 production 변환 함수를 직접 호출한다. 외부 서비스 성공을 증명하는 mock은 없다. 구조화 생성·audio·Apple generic API parity는 이 package의 추가 구현으로 간주하지 않는다. `ModelDescriptor.validateGenerationContract`를 새 registry/Hub 경계에서 재사용했으며 schema 정본을 복제하지 않았다.

**F13 / 오류 정규화 제약.** 제한된 메시지 유실은 수정했지만 raw provider error와 typed details의 durable 보존은 별개다. 현재 공통 failure에는 해당 필드가 없다. 실제 consumer 요구와 비밀정보 제거 정책을 확인하기 전 새 error schema를 확정하지 않는다.
