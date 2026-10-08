# LanguageModelRuntime·대화 façade — ANALYSIS

> Production refactor 현재 상태: [구현·리뷰](../../docs/production/IMPLEMENTATION_REVIEW.md), [검증](../../docs/production/QUALIFICATION.md). 기존 아래 baseline 수치/환경 관측과 최신 결과를 구분한다.

## Verdict·책임 경계

**방향 IMPROVE, façade MAINTAIN. 확신도 높음: 공통 상태 머신/회귀 범위, native settlement는 중간 이하.** Runtime은 한 모델 실행 lane의 admission/terminal/drain을 소유한다. 외부 caller는 Agent, NativeLanguageModels, 직접 runtime consumer다. `ModelSession` 대화와 `SessionLedger` 전이를 같은 state의 중복 writer로 판단하지 않는다. Ledger는 순수 값이며 Session이 이를 변경하는 유일한 실행 owner다. façade는 별도 분석 제품이 아니라 이 runtime의 public projection으로 포함한다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| registry 선택·획득 | ManagedAgentAssembler / host → acquireRuntime | 명시 provider/model; availability; 취소; 반환 identity | registry=등록/획득, factory=resource 생성 | owned/borrowed access 또는 failure | [ModelProviderRegistry.swift](Sources/LanguageModelRuntime/ModelProviderRegistry.swift) |
| descriptor 재사용 | host → ModelExecutorStore.runtime(for:) | Executor type + Hashable config + descriptor 일치 | host-owned store; 실제 저장값은 ModelRuntime | 동일 lane 반환; 충돌 거부 | [ModelExecutorStore.swift](Sources/LanguageModelRuntime/ModelExecutorStore.swift) |
| 실행 예약·시작 | AgentLoop / generate → reserve → start | 동일 request, capability, reservation identity | ModelRuntime phase / ModelRunControl | events, turn, runtime failure | [ModelRuntime.swift](Sources/LanguageModelRuntime/ModelRuntime.swift) |
| 현재 provider port 적응 | Runtime → ClientLanguageModel executor | same ModelClient binding; owned invocation 지원 여부 | provider task / executor wait; runtime admission | response 또는 drain failure | [ClientLanguageModel.swift](Sources/LanguageModelRuntime/ClientLanguageModel.swift) |
| 대화 응답·스트리밍 | façade / host → ModelSession | 입력, options, generation token | ModelSession + pure SessionLedger | 성공 transcript commit; 실패 rollback | [ModelSession.swift](Sources/LanguageModelRuntime/ModelSession.swift); [SessionLedger.swift](Sources/LanguageModelRuntime/SessionLedger.swift) |
| resident load/종료 | host/LocalBackendConnector → LocalBackend | configuration 범위 load; 중복/late identity | LocalBackend loadTask + host resident release | shared runtime; failed state 보존 | [LocalBackend.swift](Sources/LanguageModelRuntime/LocalBackend.swift) |
| borrowed/owned cleanup | AgentManager / host → ModelRuntimeAccess.release | ownership enum | owned만 runtime.shutdown | cleanup failure 또는 완료 | [ModelRuntimeAccess.swift](Sources/LanguageModelRuntime/ModelRuntimeAccess.swift) |

## 실제 흐름

**직접 대화 E2E:** `NativeLanguageModels.LanguageModelSession.respond → ModelSession.begin → SessionLedger.begin → ModelRuntime.generate → reserve/start → executor.respond → event validation → provider settlement → runtime idle → ModelSession cancellation/generation 확인 → ledger.commit → response`. 실패는 pending turn을 rollback한다. 완료 이벤트 관찰과 native effect 확정을 같은 것으로 보지 않는다.

**Agent E2E 접점:** Agent는 reserve 후 effect-start를 저장하고 start한다. Runtime이 Agent 원장을 기록하지 않고 Agent가 Runtime 내부 lane을 중복 구현하지 않는다.

**공유 resident:** `host 한 번 localBackend → load(중복 load join) → 동일 ModelRuntime을 borrowed로 전달 → 개별 대화 close → host.shutdown → run drain → native release`. standalone provider loader를 별도로 호출하면 자동 dedup되지 않는다.

## 현재 state·contract·I/O owner

`ModelRuntime` phase는 idle/reserved/running/draining/closing/closed/failed 계열이다. `ModelExecutorStore` key는 executor metatype와 configuration이며 runtime을 캐시한다. 이는 전역 model ID 기반 singleton도 동시 실행 pool도 아니다. 동일 config는 같은 admission lane을 공유한다. `ClientLanguageModel` reference binding은 다른 account/resident를 이름만으로 합치지 않는다.

`LocalBackend`는 loading task, resident final release를 관리하며 `ModelSession`은 한 대화만 관리한다. session close는 자신이 시작한 작업을 취소하고 borrowed runtime을 unload하지 않는다. URLSession/native handle owner는 provider에 남는다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| admission·event·terminal·drain 상태 머신 | REACHABLE | SATISFIED | PASS — Runtime 98 controlled contract tests | [model-runtime.log](../../docs/verification/imported-baseline/production-refactor-20260920/model-runtime.log) |
| conversation commit/rollback/stale 차단 | REACHABLE | SATISFIED | PASS — Runtime tests; native provider에는 별도 gate | [ModelSession.swift](Sources/LanguageModelRuntime/ModelSession.swift) |
| façade 위임 | PUBLIC_LIBRARY | SATISFIED | PASS — façade 3 tests; 독립 state/I/O 없음 | [LanguageModelSession.swift](../NativeLanguageModels/Sources/NativeLanguageModels/LanguageModelSession.swift) |
| 취소된 registry 획득 | REACHABLE | SATISFIED | PASS — 신규 7 회귀 tests | [ProviderAcquisitionCancellationTests.swift](Tests/LanguageModelRuntimeTests/ProviderAcquisitionCancellationTests.swift) |
| 모든 provider의 producer/native join | REACHABLE | PARTIAL | NOT_RUN — 실제 native; ChatGPT completion 연결 구현, full Apple qualification 남음 | [ANALYSIS.md](../../Providers/ChatGPT/ANALYSIS.md) |

## 실패·취소·복구 / findings

**F04 / 수정.** availability/목록/획득 await 뒤 취소 확인이 없어 늦은 결과를 성공으로 노출 → 신규 7 tests 수정 전 모두 실패 → task cancellation을 factory가 반드시 처리한다고 가정 → 불필요한 resource load/late publication → await 전후 경계를 명시했다. 늦은 owned access는 release한 뒤 cancellation, borrowed는 보존한다. release 실패는 cancellation에 가리지 않는다.

**F06 / 부분 검증.** 독립 buffered producer는 producer completion port를 제공해야 한다. ChatGPT는 이제 owned invocation으로 연결됐고 하위 HTTP/SSE를 join한다. 다만 full Apple client 검증은 아직 남았다. 명시적 stream EOF를 독립 native 작업의 drain 증거로 확대하지 않는다. Runtime 전체를 새 manager로 재작성하는 해결책은 부적절하다.

**F07 / 제약.** 캐시된 runtime을 consumer가 직접 shutdown하면 store가 자동 회복/recreate하지 않는다. 현행 public 반환형을 유지한다. host가 store/session shutdown 순서를 소유하는 규칙을 문서화했으며, 재생성 정책 추가는 결정 필요다.

## Gap·검증·근거

회귀는 deterministic actor gate로 취소 순서를 고정한다. Core+Runtime 실제 module을 사용하지만 probe client는 scheduler/contract 검증용이다. native loader/OS 과거 PASS를 승계하지 않는다. public function/type signature와 기존 state enum은 변경하지 않았다. registry cancellation에서 cleanup error를 보존하는 순서를 유지해야 한다.
