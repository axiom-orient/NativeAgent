# 요구사항 → 구현 → 검증 → 남은 차이

> 원본 108개 요구의 이전 대조표를 보존한다. 이 표의 기존 PASS는 이번 실행 수치가 아니다. 후속 callback 구현·native gate 상태는 [구현 리뷰](IMPLEMENTATION_REVIEW.md)와 [Qualification](QUALIFICATION.md)이 우선한다.

## 입력 문서별 검토

원본 문서는 [design input](../../design-input/production-readiness-20260920/README.md)에 변경 없이 보존했다. 단순 읽기 여부와 구현/검증 충족 여부를 구분한다. `PASS_CONTRACT`는 지정한 로컬 계약 테스트이며 native/service/제품 출시에 대한 PASS가 아니다.

| 문서·범위 | 판단·처리 |
|---|---|
| README: 세 핵심 판단 | subscription을 stable 공개 API라고 오인하지 않음; Apple façade는 후보; Agent/ASK 독립 유지. |
| Blueprint 1–3: 정체성/target/API | 기존 독립 graph/public entry 보존. 예시 API 이름을 강제 rename하지 않음. |
| Blueprint 4.1: Invocation | 읽기/producer/native receipt 분리, 실패 reference 보존, Runtime/Text/Image 회귀 추가. |
| Blueprint 4.2: Resident | 기존 LocalBackend 상태/ownership 보존, Runtime 99 테스트. 실제 driver unload는 별도 차단. |
| Blueprint 4.3: Credentials | refresh/signOut/relogin/callback/store failure/동시 cleanup 수정, Account 31 테스트. |
| Blueprint 5.1–5.3: Native | SDK/기기별 availability→load→generate→cancel→reuse→release는 BLOCKED_ENV. pin 선언만 대조. |
| Blueprint 5.4: Cloud | 새 API backend/App Server는 조건부 제안. 강제 추가하지 않음. 기존 ChatGPT는 Experimental. |
| Blueprint 6–7: Capability/Error | unsupported 기능을 silently downgrade하지 않음. 기존 failure Codable shape/semantic 보존. additive Core initializer/SPI marker 명시. |
| Blueprint 8: Artifact | lock/stage/digest/lease 구조 유지. CryptoKit 부재로 실제 Artifact test 실패; crash durability 미인증. |
| Blueprint 9: Security | secret diagnostics 제한/credential input validation 회귀. Keychain sync/동적 권한/서비스 승인·보존 정책은 G6 미완료. |
| Blueprint 10: Observability | 기존 correlation/receipt 경계 보존, 안전한 failure description 추가. 전 계층 telemetry 성능/trace 예산 실증은 미완료. |
| Blueprint 11: Test layers | unit, controlled adapter, real local HTTP, native, cloud, consumer 결과 분리. |
| Blueprint 12–13: Package/Cleanup | 새 dependency/주요 target 없음. 필요한 source closure만 실제 export·relocate. MigrationHold parity 없는 삭제 안 함. |
| Blueprint 14: Ready definition | 모든 provider 상용 완료 선언을 거부하는 게이트로 적용. 현재 전체 release BLOCKED. |
| Execution 0 | release 범위 동결. 테스트 가능한 Core/Runtime/Account/Text/Image 중심으로 작업. |
| Execution 1 | 인증·소유권 결함 수정; artifact/native 최종 완료 증명은 환경 gate. |
| Execution 2 | native qualification 미실행. 정확한 OS/model별 절차를 남김. |
| Execution 3 | 지원 상태는 명시하되 경로 rename으로 public/local dependency를 깨지 않음. 새 backend 조건부 보류. |
| Execution 4–5 | Agent kernel/Knowledge 하위 테스트 재실행. 전체 effect/ASK adapter 실사용 완료로 승격하지 않음. |
| Execution 6 | 외부 public README consumer compile/link/Core 실행. iOS/macOS host E2E의 대체가 아님. |
| Execution 7–8 | 캐시/작업 Git 제거, 원본 증거와 current 분리, 정본 문서 연결 교정. 원문 파일 수 오기 교정. |
| Execution 9 | source/pin graph·API diff·명령/로그·digest·manifest·archive 재검사. native clean checkout/binary/license 최종 승인 미완료. |
| Research Sources 1–19 | [출처별 대조와 교정](RESEARCH.md). verified external fact와 repository runtime은 구분. |

## Qualification Matrix의 항목별 상태

아래는 원본의 표 행·목록 항목·명시적 workflow를 각각 추적한다. 원본 줄 번호는 보존된 `QUALIFICATION_MATRIX.md` 기준이다. 상세 machine-readable 기록은 [requirements.json](../verification/imported-baseline/production-refactor-20260920/requirements.json)이다. 아래 상태는 상위 release gate를 자동으로 올리지 않는다.

| ID·원본 줄 | 원본 기준 | 상태 | 근거·남은 차이 |
|---|---|---|---|
| Q-001 · L9 | 입력  /  invalid descriptor/schema/limits  /  effect 시작 전 typed failure | PASS_CONTRACT | Core/Runtime tests; enumerated boundaries only, not exhaustive scheduler proof |
| Q-002 · L10 | admission  /  동시 2+ 요청, cancel before/after reservation  /  lane invariant 유지 | PASS_CONTRACT | Core/Runtime tests; enumerated boundaries only, not exhaustive scheduler proof |
| Q-003 · L11 | stream  /  normal/delta/error/EOF  /  event ordering deterministic | PASS_CONTRACT | Core/Runtime tests; enumerated boundaries only, not exhaustive scheduler proof |
| Q-004 · L12 | completion  /  EOF before producer completion  /  completion은 producer settle 뒤 | PASS_CONTRACT | Core/Runtime tests; enumerated boundaries only, not exhaustive scheduler proof |
| Q-005 · L13 | cancellation  /  각 await 지점 cancel  /  stale result commit 없음 | PARTIAL | Targeted cancellation gates pass; no exhaustive proof of every possible scheduling interleaving |
| Q-006 · L14 | session  /  success/failure/cancel/late result  /  success만 transcript commit | PASS_CONTRACT | Core/Runtime tests; enumerated boundaries only, not exhaustive scheduler proof |
| Q-007 · L15 | runtime reuse  /  same config / different config  /  identity collision 없음 | PASS_CONTRACT | Core/Runtime tests; enumerated boundaries only, not exhaustive scheduler proof |
| Q-008 · L16 | shutdown  /  active run 중 shutdown  /  intake stop→cancel→drain→release | PASS_CONTRACT | Core/Runtime tests; enumerated boundaries only, not exhaustive scheduler proof |
| Q-009 · L22 | 첫 로그인  /  credential commit revision 정확 | PARTIAL | Credential commit covered by test; Keychain/browser/OS relaunch unverified |
| Q-010 · L23 | concurrent access  /  refresh 하나만 authority | PASS_CONTRACT | Actual Account/Text tests with controlled I/O; native login separately unverified |
| Q-011 · L24 | 401 refresh  /  이전 request settle 후 재시도 | PASS_CONTRACT | Actual Account/Text tests with controlled I/O; native login separately unverified |
| Q-012 · L25 | access 중 signOut  /  stale refresh result commit 불가 | PASS_CONTRACT | Actual Account/Text tests with controlled I/O; native login separately unverified |
| Q-013 · L26 | signOut 중 access  /  credential mutation drain 존중 | PASS_CONTRACT | Actual Account/Text tests with controlled I/O; native login separately unverified |
| Q-014 · L27 | signOut caller 취소  /  cleanup 자체가 유실되지 않음 | PASS_CONTRACT | Actual Account/Text tests with controlled I/O; native login separately unverified |
| Q-015 · L28 | 재로그인  /  old generation callback 무효 | PASS_CONTRACT | Actual Account/Text tests with controlled I/O; native login separately unverified |
| Q-016 · L29 | app relaunch  /  persisted credential policy 일치 | BLOCKED_ENV | Credential commit covered by test; Keychain/browser/OS relaunch unverified |
| Q-017 · L35 | model availability 확인 | BLOCKED_ENV | Apple SDK/device/model required |
| Q-018 · L36 | session 생성 | BLOCKED_ENV | Apple SDK/device/model required |
| Q-019 · L37 | text generation | BLOCKED_ENV | Apple SDK/device/model required |
| Q-020 · L38 | structured/guided generation | BLOCKED_ENV | Apple SDK/device/model required |
| Q-021 · L39 | tool call 허용/거절 | BLOCKED_ENV | Apple SDK/device/model required |
| Q-022 · L40 | cancel | BLOCKED_ENV | Apple SDK/device/model required |
| Q-023 · L41 | session reuse | BLOCKED_ENV | Apple SDK/device/model required |
| Q-024 · L42 | app background/foreground | BLOCKED_ENV | Apple SDK/device/model required |
| Q-025 · L43 | memory pressure | BLOCKED_ENV | Apple SDK/device/model required |
| Q-026 · L44 | OS update별 prompt golden regression | BLOCKED_ENV | Apple SDK/device/model required |
| Q-027 · L53 | fresh process → → artifact acquire + digest verify → → load → → generation A → → generation B(warm) → → mid-stream cancel → → wait settle → → generation C(reuse) → → shutdown → → memory stabilization → → reload → → generation D | BLOCKED_ENV | Native driver/device/model artifacts required per provider |
| Q-028 · L69 | corrupt artifact | BLOCKED_ENV | Native driver/device/model artifacts required per provider |
| Q-029 · L70 | missing tokenizer/config | BLOCKED_ENV | Native driver/device/model artifacts required per provider |
| Q-030 · L71 | unsupported model | BLOCKED_ENV | Native driver/device/model artifacts required per provider |
| Q-031 · L72 | low storage | BLOCKED_ENV | Native driver/device/model artifacts required per provider |
| Q-032 · L73 | low memory | BLOCKED_ENV | Native driver/device/model artifacts required per provider |
| Q-033 · L74 | load waiter cancellation | BLOCKED_ENV | Native driver/device/model artifacts required per provider |
| Q-034 · L75 | native callback late/duplicate | BLOCKED_ENV | Native driver/device/model artifacts required per provider |
| Q-035 · L76 | app termination 중 download | BLOCKED_ENV | Native driver/device/model artifacts required per provider |
| Q-036 · L80 | backend-issued auth boundary; client에 service API key 없음 | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-037 · L81 | Responses normal response | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-038 · L82 | SSE streaming | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-039 · L83 | server 4xx/5xx mapping | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-040 · L84 | rate limit/retry-after | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-041 · L85 | network loss | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-042 · L86 | client cancel | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-043 · L87 | stream disconnect 후 outcome classification | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-044 · L88 | background mode/resume를 사용하는 기능은 sequence cursor replay 검증 | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-045 · L89 | logs에 Authorization/user secret 없음 | NOT_IMPLEMENTED_OPTIONAL | New OpenAI API backend not selected; not equivalent to subscription provider |
| Q-046 · L94 | prompt → → request accepted → → generation result → → decode → → content/format validation → → temp write → → digest → → atomic publish → → consumer reopen | PARTIAL | Local Image/wire contract only; public API backend and live publication not qualified |
| Q-047 · L107 | supported format/size/background | PARTIAL | Local Image/wire contract only; public API backend and live publication not qualified |
| Q-048 · L108 | malformed/empty base64 | PARTIAL | Local Image/wire contract only; public API backend and live publication not qualified |
| Q-049 · L109 | huge result guard | PARTIAL | Local Image/wire contract only; public API backend and live publication not qualified |
| Q-050 · L110 | cancel before dispatch / after dispatch | PARTIAL | Local Image/wire contract only; public API backend and live publication not qualified |
| Q-051 · L111 | request succeeded but local publication failed | PARTIAL | Local Image/wire contract only; public API backend and live publication not qualified |
| Q-052 · L112 | duplicate publication/idempotency | PARTIAL | Local Image/wire contract only; public API backend and live publication not qualified |
| Q-053 · L118 | process spawn/stdio lifecycle | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-054 · L119 | initialize→initialized 순서 | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-055 · L120 | account/login/start + completed/updated | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-056 · L121 | thread start/resume | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-057 · L122 | turn start | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-058 · L123 | item/turn event ordering | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-059 · L124 | approval request deny/allow | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-060 · L125 | turn interrupt→turn completed | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-061 · L126 | app-server crash/restart | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-062 · L127 | schema generated from **pinned Codex version**과 client decoder 일치 | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-063 · L128 | experimental API disabled by default | NOT_IMPLEMENTED_OPTIONAL | No App Server adapter selected; no process or service support claim |
| Q-064 · L136 | model suggestion만으로 side effect 불가 | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-065 · L137 | deny→effect 0 | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-066 · L138 | approve→effect 1 | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-067 · L139 | duplicate approval→effect 최대 1 | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-068 · L143 | reserve before effect | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-069 · L144 | crash before effect | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-070 · L145 | crash after remote effect / before receipt commit | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-071 · L146 | restart reconcile | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-072 · L147 | unknown outcome 자동 replay 금지 | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-073 · L151 | schema validation | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-074 · L152 | permission check | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-075 · L153 | timeout/cancel은 effect absence로 오인하지 않음 | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-076 · L154 | sensitive result redaction | PARTIAL | Kernel exact-source tests pass; real approved tool/remote crash recovery and host remain |
| Q-077 · L158 | source identity/digest | PARTIAL | Local Knowledge packages pass; root/ASKAgentTools dependency gate remains |
| Q-078 · L159 | evidence link integrity | PARTIAL | Local Knowledge packages pass; root/ASKAgentTools dependency gate remains |
| Q-079 · L160 | plan deterministic serialization | PARTIAL | Local Knowledge packages pass; root/ASKAgentTools dependency gate remains |
| Q-080 · L161 | dryRun no-write | PARTIAL | Local Knowledge packages pass; root/ASKAgentTools dependency gate remains |
| Q-081 · L162 | approved apply one-time effect | PARTIAL | Local Knowledge packages pass; root/ASKAgentTools dependency gate remains |
| Q-082 · L163 | duplicate actionID idempotency | PARTIAL | Local Knowledge packages pass; root/ASKAgentTools dependency gate remains |
| Q-083 · L164 | partial write recovery | PARTIAL | Local Knowledge packages pass; root/ASKAgentTools dependency gate remains |
| Q-084 · L165 | journal reopen | PARTIAL | Local Knowledge packages pass; root/ASKAgentTools dependency gate remains |
| Q-085 · L166 | Agent adapter가 canonical receipt를 그대로 보존 | PARTIAL | Local Knowledge packages pass; root/ASKAgentTools dependency gate remains |
| Q-086 · L172 | cold launch | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-087 · L173 | provider unavailable UI | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-088 · L174 | on-device text | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-089 · L175 | network text(지원 시) | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-090 · L176 | image generate/publish | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-091 · L177 | background during generation | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-092 · L178 | foreground resume | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-093 · L179 | cancel from UI | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-094 · L180 | memory warning | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-095 · L181 | logout/login | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-096 · L182 | terminate/relaunch | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-097 · L183 | offline mode | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-098 · L189 | MLX resident lifecycle | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-099 · L190 | Codex App Server(선택) | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-100 · L191 | multiple windows/consumers가 같은 backend를 공유할 때 owner consistency | BLOCKED_ENV | Reference iOS/macOS app real runtime not executed |
| Q-101 · L197 | G0 Contract  /  public API + state/error semantics 고정 | PARTIAL | Per-gate decisions in QUALIFICATION.md; overall production release BLOCKED |
| Q-102 · L198 | G1 Unit  /  pure/deterministic tests PASS | PARTIAL | Per-gate decisions in QUALIFICATION.md; overall production release BLOCKED |
| Q-103 · L199 | G2 Integration  /  real local I/O PASS | PARTIAL | Per-gate decisions in QUALIFICATION.md; overall production release BLOCKED |
| Q-104 · L200 | G3 Native  /  실제 SDK/device/model PASS | PARTIAL | Per-gate decisions in QUALIFICATION.md; overall production release BLOCKED |
| Q-105 · L201 | G4 Cloud  /  staging account/service PASS | PARTIAL | Per-gate decisions in QUALIFICATION.md; overall production release BLOCKED |
| Q-106 · L202 | G5 Consumer  /  실제 앱 build/run/relaunch PASS | PARTIAL | Per-gate decisions in QUALIFICATION.md; overall production release BLOCKED |
| Q-107 · L203 | G6 Security  /  secret/privacy/artifact checks PASS | PARTIAL | Per-gate decisions in QUALIFICATION.md; overall production release BLOCKED |
| Q-108 · L204 | G7 Release  /  clean checkout reproducible + SHA/provenance | PARTIAL | Per-gate decisions in QUALIFICATION.md; overall production release BLOCKED |


## 이번 루프의 종료 지점

재현된 수정 범위의 debug/release/회귀/반복 실행을 완료하고 아카이브로 고정한다. 전체 제품의 남은 기준은 [QUALIFICATION](QUALIFICATION.md)과 [PLAN](../PLAN.md)에 유지한다. native/service 환경 부재를 mock·조건부 컴파일·문서 존재로 대체하지 않는다.
