# NativeAgent 아키텍처

## 의존 방향

```text
Consuming host
└── AgentManager (optional identity/composition facade)
    ├── Agent (durable execution)
    │   ├── Domain (contracts and transitions)
    │   ├── Execution (validation, coordination and effect routing)
    │   ├── Store (session/effect/artifact persistence)
    │   └── ModelRuntime ── ModelCore
    ├── Skills ── Domain / ModelCore
    └── ModelRuntime / ModelCore

Provider adapters ── ModelRuntime / ModelCore
Tool, Browser, Web, MCP adapters ── Agent domain and host policy
Optional products ── explicit host composition
```

Host는 provider, ToolPack/service, approval policy, OS permission과 lifecycle을 연결한다. 관리되는 Agent의 진입점은 `AgentManager`이며 identity, Soul과 Skills workspace를 함께 조립한다. 따라서 `NativeAgentManager`를 선택하면 `NativeAgentSkills`와 model core/runtime도 연결된다. 저수준 `Agent`는 이 관리 계층 없이 durable execution만 사용할 때 선택한다. 두 계층은 동일한 실행 kernel을 사용한다. Product dependency는 각 package의 Package.swift를 따른다.

## 책임과 상태 owner

| Concern | Owner |
|---|---|
| 공통 model request/event/schema | LanguageModelCore |
| invocation reservation, stream terminal, 소비 pump cancel/join | LanguageModelRuntime |
| 동일 storage의 execution/recovery admission, claim release/retry | AgentStorage의 SessionExecutionAuthority |
| session transition, approval, tool/model effect | NativeAgent domain/execution |
| durable session/effect state와 artifact reference | NativeAgent Store |
| Agent definition, Soul, managed response settings | NativeAgentManager workspace |
| selected Skill state와 실행 snapshot | Skill subsystem |
| model credentials, account/network session, native resident | provider 또는 host/OS |
| 앱 UI, account choice, permission, scheduling와 composition | consuming application |

Memory, Goals, Consensus, Browser, Web, MCP와 native providers는 각각 선택된 domain/adapter 경계다. 발견 정보나 projection은 실행 권한이 아니며 새 canonical owner를 만들지 않는다.

## Operation 흐름

```text
input
→ validate and decide
→ durable transition / reserve
→ record effect start
→ perform model/tool IO
→ observe result or unknown outcome
→ validate operation identity
→ durable result / explicit recovery
→ host output
```

Request validation과 provider effect가 같은 의미 입력을 사용해야 한다. reservation, effect start, external completion과 durable result는 서로 다른 경계다. asynchronous callback은 operation identity와 현재 state가 일치할 때만 적용한다.

## 저장과 복구

Session/effect database와 filesystem artifact publication을 하나의 global transaction으로 설명하지 않는다. Store는 session/effect reference와 revision을 소유하고 artifact owner는 bytes, digest와 publication을 소유한다. 확정 후 cleanup failure도 실제 commit 결과와 구별한다.

취소는 external effect 부재를 증명하지 않는다. 불명확한 effect는 확인·조정 뒤에만 해소한다. 조정 뒤 continuation이 실패하면 이미 확정된 조정과 후속 실행 결과를 각각 보고한다.

## Provider·host 자원 수명

Provider registry는 explicit selection과 capability를 표현한다. credential/login/download/prepare 작업은 invocation reserve/start와 별도다. Provider wrapper가 빌린 native resident를 소유자인 것처럼 해제하지 않는다. LEAP/MLX 같은 공유 resident는 host/provider runtime이 drain·unload한다. C engine과 호출별 session을 직접 소유하는 adapter는 각자의 lifecycle 계약을 따른다.

## Composition 경계

앱은 필요한 products만 선택해 조립한다. NativeAgent core는 ASK나 특정 provider/MCP/UI를 요구하지 않는다. 같은 process의 연결은 consumer-local typed adapter로 수행할 수 있다. 앱의 storage placement, egress, background scheduling과 사용자 승인은 SDK가 대신 결정하지 않는다.

세부 API, format writer와 error contract는 [SPEC](SPEC.md) 및 형식별 [ADR](adr/003-v1-clean-break.md)을 따른다.
