# NativeAI — Qualification Matrix

`PASS`는 해당 행의 **실제 환경 전체 시나리오**를 통과했을 때만 부여한다. source compile 또는 mock test는 다른 provider의 PASS를 대체하지 않는다.

## 1. 공통 Runtime

| 영역 | 필수 시나리오 | 승인 기준 |
|---|---|---|
| 입력 | invalid descriptor/schema/limits | effect 시작 전 typed failure |
| admission | 동시 2+ 요청, cancel before/after reservation | lane invariant 유지 |
| stream | normal/delta/error/EOF | event ordering deterministic |
| completion | EOF before producer completion | completion은 producer settle 뒤 |
| cancellation | 각 await 지점 cancel | stale result commit 없음 |
| session | success/failure/cancel/late result | success만 transcript commit |
| runtime reuse | same config / different config | identity collision 없음 |
| shutdown | active run 중 shutdown | intake stop→cancel→drain→release |

## 2. Credential / Account

| 시나리오 | 반드시 증명할 것 |
|---|---|
| 첫 로그인 | credential commit revision 정확 |
| concurrent access | refresh 하나만 authority |
| 401 refresh | 이전 request settle 후 재시도 |
| access 중 signOut | stale refresh result commit 불가 |
| signOut 중 access | credential mutation drain 존중 |
| signOut caller 취소 | cleanup 자체가 유실되지 않음 |
| 재로그인 | old generation callback 무효 |
| app relaunch | persisted credential policy 일치 |

## 3. Apple Foundation Models

실제 지원 OS/기기별:

1. model availability 확인
2. session 생성
3. text generation
4. structured/guided generation
5. tool call 허용/거절
6. cancel
7. session reuse
8. app background/foreground
9. memory pressure
10. OS update별 prompt golden regression

특히 Apple은 OS update로 on-device model이 바뀔 수 있다고 명시하므로 **prompt behavior를 binary version만으로 고정했다고 간주하지 않는다.**

## 4. MLX / LiteRT / LEAP

각 provider와 대표 model artifact별 반복:

```text
fresh process
→ artifact acquire + digest verify
→ load
→ generation A
→ generation B(warm)
→ mid-stream cancel
→ wait settle
→ generation C(reuse)
→ shutdown
→ memory stabilization
→ reload
→ generation D
```

추가 fault injection:

- corrupt artifact
- missing tokenizer/config
- unsupported model
- low storage
- low memory
- load waiter cancellation
- native callback late/duplicate
- app termination 중 download

## 5. OpenAI API Text

- backend-issued auth boundary; client에 service API key 없음
- Responses normal response
- SSE streaming
- server 4xx/5xx mapping
- rate limit/retry-after
- network loss
- client cancel
- stream disconnect 후 outcome classification
- background mode/resume를 사용하는 기능은 sequence cursor replay 검증
- logs에 Authorization/user secret 없음

## 6. OpenAI Image

```text
prompt
→ request accepted
→ generation result
→ decode
→ content/format validation
→ temp write
→ digest
→ atomic publish
→ consumer reopen
```

검증:

- supported format/size/background
- malformed/empty base64
- huge result guard
- cancel before dispatch / after dispatch
- request succeeded but local publication failed
- duplicate publication/idempotency

## 7. Codex App Server

macOS integration 대상으로:

- process spawn/stdio lifecycle
- initialize→initialized 순서
- account/login/start + completed/updated
- thread start/resume
- turn start
- item/turn event ordering
- approval request deny/allow
- turn interrupt→turn completed
- app-server crash/restart
- schema generated from **pinned Codex version**과 client decoder 일치
- experimental API disabled by default

WebSocket transport는 공식 문서에서 experimental이므로 별 qualification 전 production default로 사용하지 않는다.

## 8. NativeAgent

### Approval

- model suggestion만으로 side effect 불가
- deny→effect 0
- approve→effect 1
- duplicate approval→effect 최대 1

### Durable execution

- reserve before effect
- crash before effect
- crash after remote effect / before receipt commit
- restart reconcile
- unknown outcome 자동 replay 금지

### Tool

- schema validation
- permission check
- timeout/cancel은 effect absence로 오인하지 않음
- sensitive result redaction

## 9. ASK / Knowledge

- source identity/digest
- evidence link integrity
- plan deterministic serialization
- dryRun no-write
- approved apply one-time effect
- duplicate actionID idempotency
- partial write recovery
- journal reopen
- Agent adapter가 canonical receipt를 그대로 보존

## 10. Host App End-to-End

### iOS

- cold launch
- provider unavailable UI
- on-device text
- network text(지원 시)
- image generate/publish
- background during generation
- foreground resume
- cancel from UI
- memory warning
- logout/login
- terminate/relaunch
- offline mode

### macOS

위 항목 +

- MLX resident lifecycle
- Codex App Server(선택)
- multiple windows/consumers가 같은 backend를 공유할 때 owner consistency

## 11. Release Gate

| Gate | 요구 |
|---|---|
| G0 Contract | public API + state/error semantics 고정 |
| G1 Unit | pure/deterministic tests PASS |
| G2 Integration | real local I/O PASS |
| G3 Native | 실제 SDK/device/model PASS |
| G4 Cloud | staging account/service PASS |
| G5 Consumer | 실제 앱 build/run/relaunch PASS |
| G6 Security | secret/privacy/artifact checks PASS |
| G7 Release | clean checkout reproducible + SHA/provenance |

Provider별로 G0~G7을 독립적으로 기록한다. 한 provider 실패 때문에 전체 SDK를 실패로 만들 필요는 없지만 **실패한 provider를 Production으로 표시하면 안 된다.**

