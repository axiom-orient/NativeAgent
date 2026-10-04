# NativeAI — SPEC

이 문서는 확정 계약과 수용 기준이다. 실제 충족 여부는 [Current](IMPLEMENTATION_STATUS.md), 세부 public 이름은 [API_MAPPING](API_MAPPING.md), Swift 원본 선언이 소유한다.

## 필수 계약

| 계약 | 입력·전제 | 출력·오류·관찰 가능한 동작 | 수용 기준 |
|---|---|---|---|
| 공통 model 계약 | 유효 descriptor/request/schema/limits | 같은 request 의미의 events/turn 또는 typed failure | invalid input이 효과 전에 거부되고 변환에서 trap/의미 변형이 없음 |
| 실행 admission | 명시된 runtime과 reservation | 한 lane에서 허용된 run; busy/conflict 명시 | request가 reservation 후 다른 의미로 바뀌지 않음 |
| terminal/drain | provider completion port와 cancellation | producer가 종료한 뒤 terminal/cleanup 또는 drain failure | EOF·cancel 요청만으로 native 종료를 선언하지 않음 |
| 대화 | imported transcript + user input + options | 성공 commit; 실패 rollback; stale generation 무효 | 실패 입력이나 늦은 결과가 committed transcript를 오염시키지 않음 |
| 수명·재사용 | host-owned store/backend; 명시 ownership | 동일 binding 재사용; owned cleanup; borrowed 보존 | 종료 실패를 숨기지 않고 해제 owner 하나 유지 |
| provider 획득 | provider/model selection, availability | identity가 일치하는 access 또는 typed error | 취소된 caller가 새 effect를 시작하지 않고 늦은 owned access를 정리 |
| Hub 설치 | 안전한 주소, explicit compatible backend | 유효한 같은 provider descriptor; 모호성은 choice/error | 취소 후 새 설치 차단, 이미 관찰한 설치 결과를 취소로 지우지 않음 |

`installAndLoad`는 install과 load의 원자적 transaction이 아니다. load 실패가 설치 취소나 파일 부재를 뜻하지 않는다. 단계별 결과가 필요한 caller는 기존 install/acquire API를 명시적으로 나누고 descriptor를 보존한다. 위 설치 결과 보존 기준은 직접 `install`의 관찰된 결과에 적용된다.

`ModelRequest/ModelEvent/ModelTurn/AgentMessage`, `LanguageModel/LanguageModelExecutor`, `ModelClient/ModelClientWithOwnedInvocation`의 실제 정의는 [Core](../Model/LanguageModelCore/Sources/LanguageModelCore/Contracts/LanguageModel.swift)와 같은 directory의 계약 파일을 따른다. 별도 JSON schema 사본을 만들지 않는다.

## 독립 제품의 선택 계약

NativeAgent를 선택하면 [Agent SPEC](../Agent/NativeAgentPackage/docs/SPEC.md)의 approval/effect identity/revision/persistence/recovery 의미를 지킨다. 모델의 tool suggestion은 실행 승인이 아니다. ASK를 선택하면 [ASK SPEC](../Knowledge/ASK/docs/SPEC.md)의 source/evidence/plan/receipt/journal 의미를 지킨다.

ASKAgentTools의 mutation은 host-bound plan/actionID, dryRun, Agent의 requireApproval, 실제 apply 순서를 사용한다. 모델이 path/plan을 바꾸지 못한다. 직접 executor를 호출하는 host는 승인 책임을 직접 가진다. apply 후 결과 불명확성은 outcomeUnknown이며 자동 replay를 허용하지 않는다.

ChatGPT image는 text provider의 자동 기능이 아니라 별도 image client/capability/skills 등록이다. 외부 요청 성공과 artifact publication, Agent DB reference commit은 구분한다. MCP/OS 도구는 caller 정책·권한과 외부 effect 불확실성을 보존한다.

## SDK·배포·비목표

NativeLanguageModels는 공통 Runtime의 편의 façade이며 Apple generic API의 drop-in replacement가 아니다. FoundationModelsBridge의 text-only 계약에 structured/macros/audio parity를 포함하지 않는다. Apple SDK availability와 compile-time symbol 존재는 각각 확인한다.

각 하위 package의 Swift tools/platform/dependency pin은 해당 Package.swift/lockfile이 정본이다. Remote Git URL은 repository-root의 범용 concrete products를 제공하고, 하위 manifest는 source-level 개발·검증 경계로 유지한다. 소비 앱의 product 조합을 SDK에 추가하지 않는다. 하위 package 폴더를 임의로 떼어 배포하지 않는다. [PACKAGING](PACKAGING.md)을 따른다.

새 UI·전역 model router·자동 cloud fallback·새 retry queue·provider SDK 업그레이드·public API 삭제는 이번 계약에 포함하지 않는다.

## 검증 수용 규칙

Requirement → implementation → reachable wiring → observable result → verification을 연결한다. PASS는 명령이 실제 조사한 범위에만 적용한다. fixture success는 native/service qualification이 아니며 environment-excluded branch는 NOT_RUN이다. 실패 명령의 exit/log는 유지한다. 현재 결과를 이 규범에 넣지 않는다.

## ChatGPT owned invocation

- Text `invocation`은 validation 이후 `onStarted`를 최대 한 번 호출하며, task 완료를 기다리는 cancellation-insensitive join을 반환한다. 정상/실패/취소의 하위 SSE/HTTP 정리가 join보다 먼저 끝나야 한다.
- Transport는 task 완료와 session 무효화 receipt를 둘 다 수집한다. 각각만으로 자원 해제나 drain 성공을 결정하지 않는다. callback 중복·도착 순서 반전은 완료를 되돌리거나 앞당기지 않는다.
- 일반 요청 실패는 events의 결과다. 완료 불명은 wait port의 실패다. Text는 기존 ModelExecutorDrainFailure로 Runtime에 전달한다.
- 401 refresh는 이전 HTTP/SSE의 join 이후 기존 횟수 정책으로만 허용한다. sign-out lease guard, mutation uncertainty, approval/receipt 의미를 변경하지 않는다.
- stream-only custom transport에 임의 no-op completion을 만들어 주지 않는다. 관리형 서비스 사용자는 invocation을 구현한다.
- HTTP 완료를 기다리던 소비 Task가 취소되면 완료 후 성공값을 반환하지 않는다. 이 취소가 원격 효과 부재를 증명하지는 않는다.


## Production completion·credential 보강

`signOut()`은 auth admission과 epoch를 먼저 닫고 sign-in/refresh producer를 join한 뒤 credential을 삭제한다. 동시 caller는 동일 cleanup을 join하며 caller 취소가 cleanup을 취소하지 않는다. 모든 서비스의 global shutdown이나 원격 revoke/rollback을 의미하지 않는다.

읽기 실패와 native 종료 실패는 별개다. 종료 증명이 실패한 invocation은 resource owner를 보존하고 재사용하지 않는다. Core retaining failure, Runtime control, Account failure roots, Image shared quarantine는 이 수명을 연결한다. 같은 실패 관측으로 owner 기록을 중복 생성하지 않는다. 자동 reset/recreate/fallback은 하지 않는다.

세부 동작·호환성·미검증 native 영역은 [구현 리뷰](production/IMPLEMENTATION_REVIEW.md)와 [qualification](production/QUALIFICATION.md)을 따른다.

## Loopback callback 계약

한 번만 실행한다: `created → starting → running → stoppingListener → drainingConnections → stopped`. 시작하지 않은 인스턴스는 제출한 native 작업이 없고, connection이 없는 listener는 취소 receipt 뒤 바로 stopped가 될 수 있다. 같은 인스턴스 재시작은 금지한다. acquired candidate를 drain한 뒤 typed EADDRINUSE인 경우만 다음 등록 port를 시도한다.

stopped는 listener cancellation 및 모든 accepted connection의 cancelled와 제출한 I/O의 정확한 completion을 요구한다. EOF, cancel 호출, deadline 경과, callback URL만으로는 부족하다. receipt 누락은 sticky shutdownTimedOut이며 SignInSession/Account ownership chain이 실패한 native handle을 보존한다. 취소된 callback caller도 cleanup을 join하고 cached success를 반환하지 않는다. 경쟁 caller는 기존 owner를 consume/cancel하지 않는다.

parser는 기존 profile의 단일 HTTP/1.1 GET endpoint를 처리한다. String 절단 전에 delimiter/한도를 byte로 확인한다. 완성된 invalid 입력은 즉시 거절한다. Host는 유일하고 선택한 endpoint와 일치해야 한다. body framing, folded/control header, trailing request는 거절하며 Content-Length: 0은 허용한다. OAuth state/code/token 검증은 Account 책임이다. 이는 특정 callback parser이며 범용 HTTP 서버/전체 HTTP 적합성 주장이 아니다.

HTTP 200은 callback 수신 알림이다. browser 알림 실패는 이미 수신한 callback을 되돌리지 않으며 로그인 성공에는 Account 검증과 token commit이 필요하다. receive/send callback의 local drain은 이 semantic 결과와 독립적으로 확인한다.

인증 재시도 인덱스는 0-based다. 음수/범위 밖 입력을 overflow 없이 거부하고 기존 유효 시도 횟수를 유지한다. portable state/parser 회귀와 실제 Apple socket 검증은 별개의 수용 계층이다.
