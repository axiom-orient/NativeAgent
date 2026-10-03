# Callback Completion Refactor — 구현·비판적 리뷰

## 결론

입력 Production Refactored 패키지의 `docs/PLAN.md`와 `HANDOFF.md`에서 callback completion/I/O isolation을 다음 구현 범위로 선정했다. accepted connection을 소유하지 않는 native 경로, complete-invalid 요청의 대기 연장, retry 산술식의 trap을 수정했다. 새 provider·gateway·외부 dependency·public wrapper는 추가하지 않았다.

**세 관점으로 반복한 동일 작업자의 비판적 자기검토다. 독립 외부 리뷰어가 참여한 것은 아니다.** 전수 graph/syntax 검사와 선택한 실행 경로의 정밀 검토를 구분한다. source/fixture 계약 테스트를 Apple/실계정 증거로 확대하지 않는다.

## 1차 — Ownership / execution path

원본은 NWListener.cancelled만 기다렸다. accepted NWConnection은 registry·state handler가 없었고 receive 작업이 callback별 MainActor Task로 넘어갔다. 따라서 listener 정리와 connection/I/O 완료가 별개라는 사실을 표현하지 못했다. 이 결함은 원본 source 경로로 확인했으며 Linux에서 실제 Network.framework를 재현했다고 주장하지 않는다.

`ChatGPTCallbackState`가 connection과 최대 한 개 pending I/O token을 소유한다. adapter는 전용 serial queue에서 API admission과 native callback을 처리한다. listener, connection.cancelled, 정확한 I/O receipt의 순열·중복·stale 결과·weak lifetime을 순수 회귀로 검증했다. start/wait의 caller identity와 취소 등록 race도 adapter에 명시했다.

## 2차 — Input / failure / regression

원본 그대로의 protocol 파일과 추출한 원본 parser 메서드를 실제 Swift로 컴파일했다. Content-Length: 8, Transfer-Encoding: chunked, NUL header가 callback으로 수락되는 것을 재현했다. complete-invalid와 incomplete가 같은 nil을 반환해 malformed 입력이 OAuth 만료까지 대기할 수 있는 경로도 확인했다. exact source SHA와 red 로그는 [baseline probes](../verification/current/regressions/baseline-probes.json)에 있다. 이것은 pure parser 재현이지 native socket 재현이 아니다.

새 parser는 byte 경계·size·endpoint·header/body framing을 확인하고 `.incomplete / .invalid / .callback`을 반환한다. OAuth state/code 검증은 Account에 남겨 decision owner를 중복하지 않았다. HTTP 200의 문구도 callback 수신 알림으로 고쳐 token 검증 이전의 로그인 성공 표시를 제거했다.

**작업 중 새 회귀도 발견했다.** Swift String에서 CRLF를 네 Character로 잘라 정상 Host와 control 검사까지 손상시켰고 테스트 3개가 실패했다. Data의 delimiter byte 범위를 먼저 자르도록 수정했다. 정상 요청·모든 유효 prefix·정확한 16 KiB 경계·trailing/pipelined bytes를 다시 검증했다. 실패 로그를 삭제하거나 테스트를 약화하지 않았다.

## 3차 — Minimality / public contract / packaging

기존 `attempt + 1`을 Int.max로 실행해 Linux에서 overflow trap(SIGILL)을 재현했다. 음수도 재시도를 허용했다. 기존 유효 0-based retry 횟수는 유지하고 음수 guard와 덧셈 없는 비교로 수정했다. Int.min/-1/0/1/2/Int.max 회귀가 있다.

connection당 I/O는 하나이므로 token Set 대신 `UUID?`로 축소했다. 동시 read/response, response 뒤 재입력, cancelled/stale receipt가 새 작업을 settle하지 못하게 검증했다. 취소 호출은 반복해도 native cancel effect를 중복 발생시키지 않는다. 5초 shutdown 상한은 성공이 아니라 sticky failure이며 Account의 기존 retained failure 경로와 연결된다.

Native socket 테스트 8개를 Agent 조립에서 Account leaf로 옮기고 6개를 추가했다. stalled connection, 여러 연결 timeout, 성공 뒤 다른 연결 drain, malformed header 즉시 거절, cached callback의 취소, admission 초과를 다룬다. 점유 test helper도 start 실패 후 acquired listener를 join하도록 고쳤다. **14개 모두 Apple 환경 실행은 NOT_RUN**이다.

## REMOVE / INTEGRATE / KEEP

| 판단 | 내용 | 근거 |
|---|---|---|
| REMOVE | callback별 MainActor Task hop, 중복 terminal/shutdown booleans, private Result wrapper, TestPortOccupier wrapper | 단일 queue/ledger/직접 pattern matching과 실제 server owner로 대체 |
| INTEGRATE | request validation → pure parser; listener/connection/I/O facts → pure ledger; native 테스트 → Account leaf | 실행·검증 경계가 실제 package owner와 일치 |
| KEEP | public products/API, manifest/lockfile/pin, OAuth/PKCE/port 순서, Keychain sync 정책, Text/Image 독립성 | 유효 계약을 바꿀 근거 없음 |
| KEEP | Agent/ASK approval·journal, borrowed LocalBackend, optional Apple/MLX/LiteRT/LEAP/Image/MCP, MigrationHold | 이번 callback 결함과 독립이며 parity 삭제 증거 없음 |
| KEEP | 기존 검증 도구와 과거 raw evidence | 실제 재검증/출처 확인에 필요. 과거 current는 imported-baseline으로 분리 |

## 실제 확인과 미확인

[Qualification](QUALIFICATION.md), [machine report](../verification/current/final-verification.json), [변경·보존 대조](../verification/current/change-review.json)가 최종 결과다. public README consumer를 재배치한 dependency closure에서 컴파일·링크했다. 실행한 것은 Core 값 계약과 미지원 host의 명시적 거부이며 로그인·이미지·모델 호출이 아니다.

검증 관찰 명령이 중간에 timeout된 한 번의 harness 실행은 중단으로 기록하고 남은 compiler process group을 명시 종료했다. 감독 가능한 재실행의 exit/log를 별도로 남겼다. Swift Testing macro의 mutating-expression harness 오류도 production 결함과 구분해 보존했다.

Current 소스에서 추가 correctness를 입증하지 못하는 전면 rewrite·새 프로토콜·dependency 변경은 하지 않았다. Native callback/Keychain/SDK·device·live service·host durability gate가 남아 production release는 BLOCKED다.


## 4차 — ModelHub identity / validation authority

추가 전수 검색에서 `HubModelAddress`와 `HubModelImportCandidate`가 동일 repository identity를 서로 다른 validator로 판정하는 duplicate authority를 발견했다. Candidate 쪽은 repository part의 문자 집합조차 제한하지 않았고, Address 쪽도 공식 Hub 제한보다 느슨했다. 이를 `HubRepositorySyntax` 하나로 수렴했다.

동시에 candidate ID가 artifact path를 comma join하여 `['a,b','c']`와 `['a','b,c']`를 구분하지 못하고 provider ID를 포함하지 않는 identity collision을 확인했다. 길이-prefix path encoding과 provider authority 포함으로 수정했다. 새로운 abstraction은 syntax owner 하나뿐이며 backend protocol·effect path는 건드리지 않았다.

변경 후 ModelHub 13 tests를 3회 반복, release build까지 warnings-as-errors로 통과했다. 상위 영향 경로는 Core 57, Runtime 99, Account 50, Text 3, Image 3 및 NativeAgent target build를 재검증했다.
