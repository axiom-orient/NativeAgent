# ChatGPT Account·Text·Image — ANALYSIS

> 2026-09-20 후속 변경: callback queue/connection/I/O ownership과 Account leaf native tests는 [현재 구현 리뷰](../../docs/production/IMPLEMENTATION_REVIEW.md)가 정본이다. 아래 이전 분석의 실행 로그는 imported-baseline이며 이번 PASS로 승계하지 않는다.

> Production refactor 현재 상태: [구현·리뷰](../../docs/production/IMPLEMENTATION_REVIEW.md), [검증](../../docs/production/QUALIFICATION.md). 기존 아래 baseline 수치/환경 관측과 최신 결과를 구분한다.

## Verdict·책임 경계

**구조 유지 + 완료 계약 보강.** Account는 인증/HTTP, Text는 catalog/SSE/model, Image는 image service를 소유한다. Agent 도구·승인·artifact publication은 상위 선택 adapter다. 기존 패키지를 합치거나 새 gateway/manager를 만들지 않았다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| 로그인·로그아웃·refresh | host → ChatGPTAccountSession | PKCE/callback/credential generation/lease | Account actor + Keychain + loopback | auth status/access lease/error | [AccountSession](Account/Sources/ChatGPTAccount/ChatGPTAccountSession.swift) |
| HTTP invocation | service → ChatGPTTransport.invocation | request/endpoint/byte limit | request마다 URLSessionChatGPTOperation | events + cancel + waitForCompletion | [Transport](Account/Sources/ChatGPTAccount/ChatGPTTransport.swift) |
| catalog/model 선택 | host/provider → ChatGPTTextSession | catalog/account epoch/model ID | TextSession catalog; Account credential | 선택 모델/한도/error | [TextSession](Text/Sources/ChatGPTText/ChatGPTTextSession.swift) |
| text invocation | Runtime → ChatGPTModelClient.invocation | ModelRequest/tool schema/output limits | model producer → SSE producer → HTTP operation | ModelEvent + owned completion | [ModelClient](Text/Sources/ChatGPTText/ChatGPTModelClient.swift), [SSE](Text/Sources/ChatGPTText/ChatGPTTextWire.swift) |
| Runtime adapter | registry → ChatGPTProviderConnector | explicit account/text/model | 기존 Runtime owner | ModelRuntimeAccess | [Connector](TextProvider/Sources/ChatGPTTextProvider/ChatGPTProviderConnector.swift) |
| image generate/edit | host / Agent adapter → ChatGPTImageClient | intent/image limits/account lease | 독립 image HTTP effect | image bytes/metadata/error | [ImageClient](Image/Sources/ChatGPTImage/ChatGPTImageClient.swift), [wire](Image/Sources/ChatGPTImage/ChatGPTImageWireCodec.swift) |

## 실제 흐름

`validate → onStarted → authorization/catalog → request → owned HTTP → SSE parser → model decoder → transport task completion + session invalidation → SSE task join → model task join → Runtime settlement`.

`onStarted`는 buffered event와 독립된 보수적 effect-start 경계다. 실제 서버가 요청을 수행했다는 receipt가 아니다. decoder의 completed event, 스트림 EOF, 로컬 완료, 원격 결과, durable commit은 같은 사건이 아니다.

HTTP 작업은 `ready → streaming → finishing`을 따른다. 별도의 순수 completion state는 `pending / taskFinished / sessionInvalidated / settled`로 두 callback의 관측을 추적한다. 둘 다 확인한 뒤에만 task/session 참조를 해제하고 completion waiter를 재개한다. task 취소 후 `finishTasksAndInvalidate()`로 세션을 종료한다. `invalidateAndCancel()` 호출이나 invalidation 하나만으로 완료를 인정하지 않는다.

401 재인증은 이전 HTTP/SSE가 drain된 뒤 기존 retry policy 안에서만 실행된다. 초기 account lease 재검증과 sign-out generation guard를 보존한다. parser 실패·oversize·consumer 취소도 하위 작업을 취소하고 join한다. drain 자체 실패는 기존 `ModelExecutorDrainFailure`로 전달한다.

## 현재 state·contract·I/O owner

Text와 Image는 서로 의존하지 않는다. Account 공유는 인증 공유이며 model admission이나 Agent approval 공유가 아니다. 단일 HTTP invocation의 완료가 Account 전체의 모든 shared refresh 종료를 의미하지 않는다. `signOut()`은 credential invalidation과 refresh cancellation을 수행하지만 전역 네트워크 shutdown API가 아니다. 이 차이를 숨기는 global owner를 추가하지 않았다.

기존 `stream`은 유지한다. 수명 소유가 필요한 caller는 `invocation`을 사용하고 조기 종료 시 cancel + wait를 수행한다. 기존 stream-only custom transport는 직접 stream 호출에 계속 사용 가능하나 관리형 서비스에는 `invocation` 구현이 필요하다. 기본 구현은 I/O 전에 기존 invalidConfiguration으로 실패한다. EOF를 가짜 native completion으로 변환하지 않는다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| Account/Text/Image 선택 의존 | PUBLIC_LIBRARY | SATISFIED | manifest/source closure 검사 | 각 Package.swift |
| HTTP/SSE/Image wire lifecycle | REACHABLE | SATISFIED | 44 exact-source tests; 실제 loopback URLSession 포함 | [wire](../../docs/verification/imported-baseline/production-refactor-20260920/chatgpt-wire.json) |
| ModelClient owned completion | REACHABLE | PARTIAL | 구현 + 3개 전체 모듈 회귀 추가; Linux CryptoKit로 full typecheck/test 미실행 | [환경 로그](../../docs/verification/imported-baseline/production-refactor-20260920/chatgpt-composition-environment.log) |
| 실계정 auth/text/image/Agent | REACHABLE | UNKNOWN | NOT_RUN — 지원 Apple SDK·계정·실서비스 필요 | [상위 PLAN](../../docs/PLAN.md) |

## 실패·취소·복구 / findings

**F06 구현 변경:** 기존 ModelClient를 `ModelClientWithOwnedInvocation`으로 연결하고 SSE와 HTTP에도 독립된 completion port를 추가했다. 정상·실패·취소 경로가 하위 join을 거친다. full Apple client qualification은 아직 열려 있으므로 F06 전체를 상용 PASS로 닫지 않는다.

**R02 redirect race:** redirect delegate가 completionHandler(nil)보다 먼저 세션을 취소하던 경로에서 실제 Linux FoundationNetworking fatal error를 관측했다. redirect는 nil로 거절하고 task 완료 후 오류를 정리한다. redirect 대상 미호출을 실제 서버 기록으로 검증했다. [재현 로그](../../docs/verification/imported-baseline/production-refactor-20260920/regressions/redirect-callback-before.log).

**R03 late cancellation:** Image/Account의 공통 HTTP 소비 경계가 drain 도중 취소되면 결과를 성공 반환하지 않도록 마지막 취소 검사를 추가했다. 원격 mutation 부재나 rollback이라고 해석하지 않는다.

**R04 completion 증거:** task completion과 session invalidation은 별도 receipt다. 도착 순서 반전·중복을 순수 state 테스트로 고정했고 실제 URLSession cancellation/reuse/오류를 별도로 실행했다.

## Gap·검증·근거

44개는 wire/local HTTP 검증이며 full AccountSession/ModelClient/ImageClient·live service 검증이 아니다. 3개 full ModelClient 회귀는 지원 Apple 환경에서 실행해야 한다. callback 자체를 주지 않는 외부 구현은 완료를 증명할 수 없으므로 wait를 성공시키지 않는다. wall-clock 상한이나 원격 중단을 보장한다고 주장하지 않는다. [검토 결과](../../docs/REVIEW_20260920.md), [검증](../../docs/verification/README.md).
