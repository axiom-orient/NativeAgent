# ASKAgentTools — ANALYSIS

## Verdict·책임 경계

**방향 MAINTAIN. 확신도 높음: 고정 plan projection/authority 경계, 실제 Agent+ASK integration UNKNOWN.** adapter는 ASKClient를 Agent ToolExecutor로 투영한다. 새 plan writer, 승인 state, DB, task, retry queue를 만들지 않는 점이 타당하다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| query tool 생성 | host → queryTool(typedQuery) | query host-bound; model arguments 빈 object | ASK query; Agent read tool | typed query projection/error | [ASKAgentTools.swift](Sources/ASKAgentTools/ASKAgentTools.swift) |
| mutation 준비 | host → prepare(command) | ASK plan/dryRun; 고정 actionID/preview | ASK plan, adapter closure capture | prepared tool+preview | [ASKAgentTools.swift](Sources/ASKAgentTools/ASKAgentTools.swift) |
| Agent 실행 | Agent approval/ledger → tool.execute | name/arguments exact equality; before-dispatch cancel | Agent approval/effect; ASK apply/knowledge | receipt 또는 ASKApplyFailure.outcomeUnknown | [ASKAgentTools.swift](Sources/ASKAgentTools/ASKAgentTools.swift) |

## 실제 흐름

`host command → ASKClient.plan → dryRun → bound tool(requireApproval, mutation) → Agent registration → schema + approval + durable start → exact actionID/name 재확인 → ASK dryRun/apply → observed receipt → Agent result commit`. model은 경로/command/plan을 다시 작성할 수 없다. tool executor 직접 호출은 신뢰된 host API이며 그 자체가 승인 엔진은 아니다.

## 현재 state·contract·I/O owner

승인과 실행 원장은 Agent, plan/preview/지식/receipt는 ASK, argument→typed call 매핑만 adapter다. apply 반환 후 cancellation check로 receipt를 버리지 않는다. 실패에는 actionID와 underlyingError를 보존하며 unknown outcome을 자동 재시도하지 않는다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| 고정 plan/query projection | PUBLIC_LIBRARY | SATISFIED | PASS — source/schema/graph inspection | [ASKAgentTools.swift](Sources/ASKAgentTools/ASKAgentTools.swift) |
| 실제 Agent approval → ASK receipt 통합 | PUBLIC_LIBRARY | UNKNOWN | NOT_RUN — 7 integration tests dependency resolve 실패 | [ask-agent-attempt.log](../../../../docs/verification/imported-baseline/ask-agent-attempt.log) |

## 실패·취소·복구 / findings

현재 adapter에서 중복 state/권한 owner를 발견하지 못했다. “Agent 승인”을 “모델이 호출하기로 선택”과 혼동하면 안전 경계가 무너진다. public executor만 직접 호출하는 host는 승인 책임을 직접 가진다.

**F12 / 남음:** 실제 Agent denied/approved/replayed/after-commit-error 통합은 source만으로 확정하지 않는다. root ASK를 stub으로 대체한 테스트는 해당 gate의 대체물이 아니다.

## Gap·검증·근거

실제 swift-markdown 의존성을 resolve한 환경에서 원래 package 테스트를 실행해야 한다. denied에 파일 변화 없음, approve의 receipt, duplicate actionID, 중복/late 취소, 원장 commit 실패를 actual ASK workspace로 확인한다. adapter를 Agent 필수 dependency로 올리지 않는다.
