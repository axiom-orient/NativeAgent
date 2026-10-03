# NativeAgentMCP — ANALYSIS

## Verdict·책임 경계

**방향 MAINTAIN. 확신도 중간: adapter 계약, 실제 MCP peer UNKNOWN.** 외부 MCP tools를 Agent tool contract로 연결하는 선택 library다. MCP discovery와 Agent approval은 다르다. Node/server/process를 core에 강제하지 않는다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| tool catalog·call | host → MCP adapter → MCPClientTransport | endpoint/tool schema/call/host policy | external peer + adapter; Agent가 승인 | tool definition/result/error | [MCP.swift](Sources/NativeAgentMCP/MCP.swift) |
| 취소 전달 | Agent cancellation → wrapped exchange.cancel | 원래 exchange identity/reason | MCPCancellationSafeTransport가 cleanup task join | cancel notification result/error | [MCPCancellationSafeTransport.swift](Sources/NativeAgentMCP/MCPCancellationSafeTransport.swift) |
| transport shutdown | host → base transport lifecycle | host resource scope | host/external MCP transport | 닫힘 또는 오류 | [MCPCancellationSafeTransport.swift](Sources/NativeAgentMCP/MCPCancellationSafeTransport.swift) |

## 실제 흐름

`host가 transport 연결/등록 → tools catalog → Agent tool schema/approval/start ledger → MCP open/call → frames → ToolResult → Agent commit`. 취소 알림은 이미 취소된 caller에 묶이지 않는 detached task로 보내되 `.value`를 await한다. 이는 fire-and-forget가 아니다. remote 서버가 effect를 수행하지 않았다는 보장은 아니다.

## 현재 state·contract·I/O owner

base transport 종료는 host, exchange cancel notification은 adapter, 효과 원장은 Agent다. registry reporting/catalog invalidation은 조건부 protocol forwarding이며 새로운 tool authority가 아니다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| MCP public adapter | PUBLIC_LIBRARY | PARTIAL | NOT_RUN — exact dependency/peer integration | [MCP.swift](Sources/NativeAgentMCP/MCP.swift) |
| 취소 알림 join 구조 | PUBLIC_LIBRARY | SATISFIED | PASS — source control flow; 실제 transport는 NOT_RUN | [MCPCancellationSafeTransport.swift](Sources/NativeAgentMCP/MCPCancellationSafeTransport.swift) |

## 실패·취소·복구 / findings

전송 취소의 성공을 원격 mutation rollback으로 해석하지 않는다. 기존 detached task를 actor 과용/숨은 백그라운드 작업으로 일괄 제거하면 cancellation notification이 유실될 수 있다. task lifecycle이 기다려지는지와 host transport 수명을 분리해 유지한다.

## Gap·검증·근거

`swiftMcp` pin·manifest와 qualification consumer는 보존했다. 실제 stdio/HTTP peer auth, process death, tool catalog 변경, in-flight mutation의 응답 유실은 NOT_RUN. source-order 검사만으로 해당 시나리오 PASS를 선언하지 않는다.
