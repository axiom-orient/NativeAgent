# AGENTS.md — NativeAgent

상위 [`../../AGENTS.md`](../../AGENTS.md)를 먼저 적용한다.

## Authority

- `LanguageModelCore`: request/event/schema value contract.
- `LanguageModelRuntime`: invocation admission, cancellation, drain, runtime shutdown.
- Agent domain/execution: approval, effect identity, state transition.
- Store: durable session/effect/result references.
- AgentManager: managed composition, identity, Soul/Skills workspace.
- Provider/host: credential, network session, downloaded/native resident.

이 owner를 합치는 새 manager/singleton을 만들지 않는다.

## 변경 시 확인

- low-level `Agent`와 optional `AgentManager`가 같은 durable execution semantics를 유지하는가.
- tool/model effect가 approval/effect-start 기록을 우회하지 않는가.
- stale/late/cancelled result가 current operation을 덮어쓰지 않는가.
- borrowed runtime을 AgentManager cleanup이 shutdown하지 않는가.
- provider-specific I/O가 ModelCore/Domain pure types로 침투하지 않는가.
- optional capability 때문에 base package dependency가 증가하지 않는가.

## 문서

`ANALYSIS.md`는 세부 Current 근거이며 상위 Current가 요약·참조한다. Canonical docs는 `docs/{IDENTITY_AND_EVOLUTION,ARCHITECTURE,SPEC,IMPLEMENTATION_STATUS,VERIFICATION,PLAN}.md`다. 임시 분석·세션 로그는 canonical docs로 승격하지 않고 제거하거나 verification evidence로 격리한다.

## 검증

ModelCore/Runtime 변경은 각 package `swift test`를 실행한다. kernel 변경은 workspace root의 `python3 tools/verify-native-kernel.py`를 추가한다. Apple-only/provider/device 기능은 실제 환경이 없으면 `NOT_RUN`으로 남긴다.
