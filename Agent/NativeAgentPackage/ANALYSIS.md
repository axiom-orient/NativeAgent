# NativeAgent 실행 시스템 — ANALYSIS

## Verdict·책임 경계

**방향 MAINTAIN/IMPROVE. 확신도 높음: kernel durable flow 및 exact-source tests; 전체 native/Manager는 중간 이하.** 독립 제품 정체성은 provider-independent durable agent execution SDK다. caller는 앱의 저수준 Agent 또는 optional AgentManager다. 가치는 model/tool effect를 승인·원장·복구에 연결하는 것이다. Agent가 단순 ModelSession wrapper가 아니므로 둘을 합치면 승인·durability가 유실된다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| 저수준 public entry | host → Agent → SessionCoordinator | session/input/configuration | session execution authority + coordinator | snapshot/events/waits/failure | [Agent.swift](Sources/NativeAgent/Public/Agent.swift); [SessionCoordinator.swift](Sources/NativeAgentExecution/Coordinator/SessionCoordinator.swift) |
| managed entry | host → ManagedAgentAssembler → registry | workspace/Soul/Skills/model selection | Manager=composition; registry=runtime acquisition | Agent + ownership-aware cleanup | [ManagedAgentAssembler.swift](Sources/NativeAgentManager/ManagedAgentAssembler.swift) |
| model effect | AgentLoop → reserve → persist start → runtime.start | frozen request, effect identity, reservation | Agent durable effect; Runtime run lane | turn 또는 unknown outcome | [AgentLoop.swift](Sources/NativeAgentExecution/AgentLoop/AgentLoop.swift) |
| tool effect | AgentLoopToolProcessor → approval → executor | tool schema/arguments/approval/effect ledger | Agent approval/start/result; tool 외부 effect | ToolResult / needs approval / unknown | [AgentLoopToolProcessor.swift](Sources/NativeAgentExecution/AgentLoop/AgentLoopToolProcessor.swift) |
| durable state commit | coordinator/loop → SQLiteSessionStore | session ID; expectedRevision; owned records | SQLite transaction; artifact references | committed snapshot 또는 conflict | [SQLiteSessionPersistence.swift](Sources/NativeAgentStore/SQLite/SQLiteSessionPersistence.swift) |
| artifact bytes/publication | tool result → artifact store adapter | digest/session identity/validated paths | filesystem artifact owner; DB는 references | artifact references 또는 partial failure | [SQLiteSessionArtifacts.swift](Sources/NativeAgentStore/SQLite/SQLiteSessionArtifacts.swift) |
| recovery·동시 실행 차단 | host → SessionExecutionAuthority/coordinator | storage/session ownership, effect evidence | execution claims + persistent state | 재개/대기/명시적 failure | [SessionExecutionAuthority.swift](Sources/NativeAgentExecution/Execution/SessionExecutionAuthority.swift) |

## 실제 흐름

**대표 E2E:** `host Agent.run → coordinator claim → input/transition → requestBuilder → ModelInvocationLedger decision → Runtime.reserve → effect-start 원장 commit → Runtime.start → RuntimeModelRunConsumer → final result/event/snapshot commit → host output`. effect start 이전에는 provider 실행을 시작하지 않는다. reservation 실패/포기 시 미사용 reservation을 해제한다.

**write 역추적:** `ToolExecutor.execute ← AgentLoopToolProcessor ← tool schema + approval + ledger decision`. 실행 결과가 반환된 뒤 persistence에서 실패한 경우 “도구가 실행되지 않았다”로 되돌리지 않는다. SQLite `commitTransaction`은 expected revision·동일 session records를 검증하고 transaction 안에서 반영한다. DB와 외부 HTTP/파일 시스템을 분산 transaction으로 묶지 않는다.

**복구:** started 후 결과 미확정이면 wait/reconciliation으로 간다. 자동 retry로 같은 effect를 중복 실행하지 않는다. caller cancellation은 원격 효과 부재 증명이 아니다.

## 현재 state·contract·I/O owner

SessionExecutionAuthority=동일 storage execution/recovery admission; Coordinator/Domain=Agent state transition; Store=durable session/effect/result refs; ModelRuntime=한 invocation; Manager=identity/Soul/Skills 조립; Provider=credential/native/transport.

선택 products의 owner는 분리한다. Memory/MemoryProjection은 파생 기억·SQLite projection, Goals는 goal/continuation, Evolution/EvolutionSkills는 proposal/evaluation/apply, Consensus는 role/evaluation 결과, Skills는 선택 skill/workspace/snapshot, Web/Browser/Tools는 외부 I/O·OS 권한이다. 모두 존재하는 public/optional surface이며 실제 앱 caller가 archive에 없다는 이유로 Dead 판정하지 않는다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| kernel admission/approval/원장/복구 | REACHABLE | SATISFIED | PASS — exact-source kernel 571 Swift Testing + 3 XCTest; Manager 제외 | [native-kernel.json](../../docs/verification/imported-baseline/production-refactor-20260920/native-kernel.json) |
| 실제 root manifest kernel target | PUBLIC_LIBRARY | SATISFIED | PASS — swift build --target NativeAgent | [native-root-build.log](../../docs/verification/imported-baseline/production-refactor-20260920/native-root-build.log) |
| AgentManager 전체 product | PUBLIC_LIBRARY | UNKNOWN | NOT_RUN — full package NaturalLanguage 불가 | [native-root-full-test.log](../../docs/verification/imported-baseline/native-root-full-test.log) |
| Memory/Goals/Evolution/Consensus/Skills | PUBLIC_LIBRARY | PARTIAL | PASS — 포함된 non-Apple tests; 실제 host 시나리오 NOT_RUN | Package.swift/Sources/Tests |
| Files/Web/Browser/OS Tools | PUBLIC_LIBRARY | UNKNOWN | NOT_RUN — OS 권한·실제 network/UI effects; portable 일부는 전체 proof 아님 | Sources/NativeAgentTools, NativeAgentWeb, NativeAgentBrowser |
| ChatGPT/ASK/MCP optional integration | PUBLIC_LIBRARY | PARTIAL | NOT_RUN — full adapter composition; 별도 ANALYSIS | Packages 및 Knowledge/ASK/Packages/ASKAgentTools |

## 실패·취소·복구 / findings

kernel의 approval/effect/recovery owner를 합치는 구조 변경 근거는 발견하지 못했다. **F04 영향:** Manager의 registry 획득 경계에 late cancellation 문제가 있었으며 공통 registry 수정으로 처리했다. Manager 자체 native test는 수행하지 못했다.

**F06 영향:** runtime common tests가 실제 ChatGPT drain을 보장한다는 주장은 제거했다. 모델 결과와 effect 완료 여부의 불확실성을 계속 원장에 남겨야 한다.

**F11 / 문서 수렴:** 이전 Current의 “구현/외부 consumer 검증” 표기는 reachability와 실제 device 결과를 구분하지 않았다. detailed ANALYSIS와 Current 요약을 분리하고 package 이동 이후 stale 문서/임시 보고 참조를 정리한다.

## Gap·검증·근거

코드·manifest·resource 변경 없음. syscall/OS API 각각의 모든 production 실행은 미검증이다. Optional product의 public/manifest/source surface를 조사했으며 각 실제 업무 앱의 composition root는 archive 범위 밖 UNKNOWN이다. 순수 kernel fixture 성공을 실제 모델 성공으로 보고하지 않는다.

## Material unit 포함 판단

| 단위 | 분류 | 이유·조사 범위 |
|---|---|---|
| Domain/Execution/Store | 상위 포함 | 같은 Agent 실행 계약의 core/state/effect persistence; 대표 read/write/recovery 경로 상세 추적 |
| AgentManager | 상위 포함 | 별도 product지만 kernel의 managed composition; registry/cleanup 추적, Apple runtime 미실행 |
| Skills/Memory/Goals/Evolution/Consensus | 상위 포함·선택 | 각 domain state와 exports 유지; kernel test 포함 범위만 검증, 실제 host scheduling 미조사 |
| Web/Browser/Tools/HTML/SkillsWeb | 상위 포함·외부 effect | 권한/서비스/OS callback 경계 식별; 실제 기기별 실행 NOT_RUN |
| ChatGPTAgent/ImageCapability/MCP | 독립 adapter 분석 | optional package graph·효과/transport 위험이 kernel과 다름 |
| ResponsePolicies/SkillSources | 실행 입력·보존 | 일반 설명 문서가 아니며 byte 유지 |
