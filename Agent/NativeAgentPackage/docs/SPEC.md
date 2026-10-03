# 제품 규격 — NativeAgent

이 문서는 NativeAgent public behavior와 수용 기준을 정의한다. 정확한 API와 schema는 연결된 source가 정본이며 first-party format 경계는 [clean-break ADR](adr/003-v1-clean-break.md)를 따른다.

## 필수 기능·전제조건

Host는 지원 toolchain/OS의 필요한 public product를 의존하고, 명시 provider/model 또는 ModelClient, 유효 storage root, 승인 정책, 필요한 ToolPack/service를 구성한다. provider credentials/model resources/OS permission 및 application lifecycle은 host 책임이다. 무권한·미준비는 성공 대신 명시 오류다.

| 계약 ID | 필수 의미 | 관찰 가능한 수용 기준 | API·schema 원본 |
|---|---|---|---|
| N01 | provider-independent session 실행 | run/send의 입력·model/tool 결과·session revision을 저장하고 다시 읽을 수 있음 | [Agent](../Sources/NativeAgent/Public/Agent.swift), [SessionSnapshot](../Sources/NativeAgentDomain/Values/SessionSnapshot.swift) |
| N02 | 입력·capability·자원 검증 | invalid schema/unsupported modality/tool/output/limit는 해당 effect 시작 전 오류 | [Core contracts](../../../Model/LanguageModelCore/Sources/LanguageModelCore/Contracts/ModelContracts.swift), [ToolCallValidator](../Sources/NativeAgentExecution/Tools/ToolCallValidator.swift) |
| N03 | approval/typed execution | 등록된 executor+정확한 schema+host 승인이 충족돼야 effect를 시작. metadata는 승인 아님 | [ToolSchema](../../../Model/LanguageModelCore/Sources/LanguageModelCore/Schema/ToolSchema.swift), [Agent processor](../Sources/NativeAgentExecution/AgentLoop/AgentLoopToolProcessor.swift) |
| N04 | operation identity·revision | queue/edit/retry/fork와 재개는 유효 state/precondition 아래 수행; 충돌·stale를 덮어쓰지 않음 | [Agent public API](../Sources/NativeAgent/Public/Agent.swift), Domain/Store 원본 |
| N05 | wait/recovery | 승인·signal/time·model/tool 결과 불명·claim release를 조회·조정·재개. host 깨우기 없이 자동 daemon 보장 안 함 | [Agent](../Sources/NativeAgent/Public/Agent.swift) |
| N06 | durable effect와 artifact | 파일 bytes/digest·session 참조·effect 결과가 일치하며 publication 실패가 드러남 | [result handler](../Sources/NativeAgentExecution/AgentLoop/AgentLoopToolResultHandler.swift), [store](../Sources/NativeAgentStore/SQLite/SQLiteSessionStore.swift) |
| N07 | invocation 수명 | reserve와 실행 start를 분리; terminal·stream 종료·cancel/drain·shutdown을 관찰 가능하게 처리 | [ModelRuntime](../../../Model/LanguageModelRuntime/Sources/LanguageModelRuntime/ModelRuntime.swift), [ModelRunControl](../../../Model/LanguageModelRuntime/Sources/LanguageModelRuntime/ModelRunControl.swift) |
| N08 | identity/authority 보존 | ManagedAgent의 Agent ID/provider/model/Soul/Skill pin이 다른 session에 섞이지 않음 | [Manager](../Sources/NativeAgentManager/AgentManager.swift), [AgentDefinition](../Sources/NativeAgentManager/AgentDefinition.swift) |
| N09 | first-party 형식별 단일 현재 버전 | 현재 형식만 읽고 쓰며 구버전·필수 필드 누락을 명시적으로 거부. 자동 변환·초기화·구형 effect 재실행 금지 | 해당 source declaration·[ADR003](adr/003-v1-clean-break.md) |

공개 타입의 정확한 필드·enum·기본값·한도는 연결된 Swift 선언과 schema가 정의한다. 문서의 새 JSON 예시가 별도 authority가 되지 않는다. target별 boundary 상세의 source links를 함께 따른다.

## 입력·출력·오류 의미

| 경계 | 입력·전제 | 출력·오류·금지 |
|---|---|---|
| model | canonical ModelRequest, 명시 selection, 지원 capability·한도 | ModelEvent/ModelTurn 또는 오류. 계정/모델/billing path 무음 교체 금지 |
| tool | 등록 이름, typed arguments, context/session identity, approval | ToolResult/ArtifactWriteRequest 또는 명시 실패. 실행·publication 결과 불명은 별도 보존 |
| durable data | owner scope, schema version, 필수 필드, ID/revision/path/digest | 정확한 decode 또는 unsupported/corrupt/conflict 오류. 기존 잘못된 파일을 빈 state로 취급 금지 |
| artifact edit input | 실제 inline bytes 또는 해석 가능한 현재 session artifact 참조+exact digest | 존재·유형·scope·bound·integrity가 확인된 bytes만 사용. opaque ID로 이미지를 발명하지 않음 |
| provider/OS callback | 명시 host lifecycle, request identity, permission/availability | 대응하는 현재 operation 결과만 반영. cancel 이후 stale callback으로 최신 state 덮기 금지 |
| recovery | pending effect/claim/session identity + 실제 관찰 또는 승인된 reconciliation | 조정 결과와 후속 continuation 결과 분리. 앞의 commit을 뒤의 오류 때문에 미반영처럼 보고 금지 |
| discovery | 등록된 library/capability/tool metadata | 발견 결과와 실행 권한·실서비스 검증은 구분. concrete service 없는 곳에 stub 성공 금지 |

오류 구분은 invalid/unsupported, denied/unavailable, conflict/stale, definite execution failure, unknown external outcome, persistence/publication/cleanup failure를 보존해야 한다. 모든 오류를 하나의 빈 결과나 성공 status로 바꾸지 않는다.

## 실행 점유와 모델 취소

실행과 provider-independent recovery는 같은 `AgentStorage`의 `SessionExecutionAuthority`를 통과한다. claim release 실패와 release retry도 이 owner에 귀속된다. `coordinatorOnly`는 이 공유 storage 범위만 보호하며, 별도 storage/process의 상호 배제에는 `.sharedClaimRequired`를 사용한다.

`ModelRun.cancel()`의 완료는 runtime 소비 pump 종료를 뜻한다. buffered adapter producer, native drain, remote effect의 종료나 rollback을 증명하지 않는다. model run 생성 후 cancellation/deadline은 기존 `waiting/modelInvocation`과 started receipt를 유지한다. caller cancellation은 그대로 반환하지만 자동으로 definite failure/retry 권한으로 바꾸지 않는다. 미해결 invocation은 기존 recovery API로 관찰·조정한 뒤 재개한다. provider 진입 전 취소는 예약을 해제하고 provider를 호출하지 않는다.

## 선택 기능·활성 조건

선택 기능은 default Manager 등록 여부와 무관하게 정당한 public 사용 방식이다. 각 product는 필요한 host 주입점을 공개하고 독립 consumer에서 조립 가능해야 한다. 선택되지 않은 기능을 kernel 필수 dependency로 승격하지 않는다.

| 기능 | 활성 조건·호출 | 보존할 의미·수용 기준 |
|---|---|---|
| Skills/SkillsWeb | 선택된 immutable Skill snapshot; tool-capable runtime; 필요시 명시 script runner | catalog→load_skill→read_skill_file; run_js는 local-pure/기본 disabled; run_intent는 exact selected binding+handler schema+approval |
| Native writing / character | Manager response 설정 또는 직접 Agent의 turn augmentor | 현재 언어 지침만 로딩, soul+프로필 대화, 윤문 시 원문 목소리 보존. Swift 검사는 의미 성공을 주장하지 않음 |
| Memory | host controller/transcript source/decorator/tool pack 조합 | source·scope·provenance 보존, 요청 전 회수와 post-response capture 구분, 삭제/forget 범위를 명시 |
| Goals | host evaluator/runner/store/claim/continuation | bounded 목표 상태와 실행 session state 분리, 근거 없는 satisfied를 강제하지 않음 |
| Evolution/EvolutionSkills | dataset·candidate/evaluator·report store + 명시 승인 adapter | review와 apply 분리; apply 시 원본 digest/precondition 재확인; 보호된 Skill의 정책 유지 |
| Consensus | explicit routing selector 또는 직접 runner/roles | 비용·round 한도, strict role output; 합의는 사실/권한 확정 아님 |
| Browser/HTML | Apple host-owned WebKit session+정책·callbacks | page revision/node identity, navigation/JS/cancel/host transfer 분리. interactive HTML과 pure Skill script 계약 혼동 금지 |
| Files/native Tools | host sandbox/service와 OS permission/entitlement | 각 파일/Calendar/Contacts/Photos/Health/Maps/NFC/Speech/Vision/AppIntent별 실제 결과·오류 유지 |
| Web | concrete WebSearchService/WebFetchService 주입 | provider cursor/redirect/network 정책과 tool input/output validation 분리 |
| MCP | host client/transport/auth/process lifetime | bounded discovery/schema/output, explicit remote error, readOnlyHint만으로 approval 생략 금지, reconnect host-owned |
| native providers | qualified local model/SDK/OS/기기·capability | wrapper/engine/resident lifetime별 cancel/drain/unload를 구분하고 unsupported 요청 사전 거부 |
| ChatGPT image capability | 명시 account+schema+approval+실제 image input(편집) | canonical images.generate/edit, PNG facts와 요청 constraints, artifact publication, no silent provider fallback |

## 이미지 산출물 수용

일반 tool은 `images.generate`와 `images.edit`이며 effect Skill은 recipe/intent binding만 제공한다. 생성 입력의 prompt/background/quality/size/output filename, 편집 입력의 inline/reference 배타 조건은 [ChatGPTImagesCapability](../Packages/ChatGPTImageCapability/Sources/ChatGPTImageCapability/ChatGPTImagesCapability.swift)의 schema를 따른다.

반환 bytes는 파일 형식·bound·width/height·digest를 확인하고 명시 alpha 요구는 실제 decode로 판정한다. `verified`는 해당 deterministic 제약이 확인됨을, `structural_only`는 충분한 판정이 없음을, `needs_repair`는 관찰한 제약 불일치를 의미한다. [검증 원본](../Packages/ChatGPTImageCapability/Sources/ChatGPTImageCapability/ChatGPTImageVerification.swift)을 따른다.

실패 제약의 진단 artifact를 저장하는 것은 허용하되 성공으로 표시하지 않는다. artifact 저장 성공·사용자 요구 충족·예술적/의미적 품질은 서로 다른 판단이다. correlation ID는 remote exactly-once 보증이 아니다.

## first-party 형식·clean break 수용

새 first-party 저장/교환 형식마다 하나의 owner·version 식별자·producer·strict decoder·오류 정책을 정한다. transient 값 타입과 외부 protocol까지 동일 전역 version enum에 묶지 않는다. 이름이 바뀌면 schema/metadata/tool IDs/hash domains/JS entrypoint/Keychain scope/path/release consumers를 함께 갱신한다.

승인된 형식의 정상 round-trip, missing required field, unknown/old/future version, 잘못된 타입·ID·path·digest, 동일 identity의 다른 payload, 재시작 읽기를 시험한다. unsupported persisted data는 오류로 남기고 빈 상태로 복구한 것처럼 보이지 않는다. 없는 파일의 최초 bootstrap은 별도 정상 경로다.

형식별 현재 계약은 [ADR003](adr/003-v1-clean-break.md)을 따른다. Memory projection과 model invocation은 현재 v2 형식만 허용하며 구버전 reader와 migration을 제공하지 않는다. 지원하지 않는 effect 기록은 복구 오류로 남기고 provider에 다시 전송하지 않는다. 기존 데이터는 자동 변환하거나 삭제하지 않는다. 새 저장소를 사용할 때는 별도 data root를 명시하며, 미해결 외부 effect가 없다고 간주해서는 안 된다. 외부 SDK/OS/model revision과 third-party notices는 원래 계약을 유지한다.

## 지식·장기기억 확장 수용 경계

선택된 외부 지식 서비스에 연결할 때 source ID/revision·scope·획득/유효 시점·출처·확정/추정/충돌을 구분한다. 지식 문서는 데이터이고 Soul/approval을 덮어쓸 권한이 아니다.

Agent commit과 외부 knowledge commit은 별도 authority다. 외부 factual owner를 사용하는 managed Agent는 `AgentKnowledgeOwnership.externalKnowledgeBase`를 선택해 local `MEMORY.md` writer를 동시에 활성화하지 않는다. NativeAgent가 외부 knowledge system의 outbox/cursor/API를 소유하거나 integration adapter를 필수화하지 않는다.

사용자 변경·망각은 원본·projection·prompt cache·export 정책에 맞게 전파한다. 외부 반출 파일 회수와 transcript 보존의 한계를 설명한다. recall 성공뿐 아니라 재시작 후 실제 tool arguments가 올바른지 검증한다.

같은 scope의 지식 writer는 하나로 식별되어야 하며 transcript·실제 model input·curated fact·추출 memory를 이름만 달리하여 같은 정본으로 병렬 관리하지 않는다. 본문 저장을 참조로 바꿀 경우 실제 model request와 복구 fingerprint를 정확히 재구성할 수 있어야 한다. 구체 외부 SDK·schema·package 채택은 별도 결정이며 이 규격이 승인하지 않는다.

## 검증 계약

독립 public consumer compile, focused/integration tests, 실제 플랫폼·provider·peer·OS 결과를 구분한다. mocks/scripted clients는 내부 계약의 증거일 뿐 production 기능의 proof가 아니다. build/test/runtime/미적용 상태와 source identity·command·환경·관찰 산출물을 연결한다. release archive integrity와 product qualification은 별도 gate다.

## durable request admission

ModelClient.invocationSemantics는 provider port의 의미 계약이다. default exactRequest는 전달된 request를 숨은 augmentation 없이 소비한다는 계약이며 arbitrary 외부 구현의 정직성을 runtime이 자동 검증한다는 뜻은 아니다. MemoryModelClient는 standaloneOnly이고 ModelRuntime.init은 이를 invalidConfiguration으로 거부한다. 동일 제약을 감싼 first-party routing wrapper는 base 계약을 전파해야 한다. standalone generate/stream/controller API는 보존한다.

취소된 standalone memory preparation의 late 결과는 base provider에 진입할 수 없다. sync가 이미 수행한 memory I/O의 rollback을 보장하는 계약은 아니다. 명시 Consensus aggregate는 별도 child operations를 가질 수 있으며 outer input과 물리적 단일 provider request를 같다고 설명하지 않는다. Core와 optional qualification은 독립이다.

## standalone memory의 reset·forget·늦은 결과

`MemoryController.delete(scope:)`는 기존 projection 초기화다. 원래 transcript가 있으면 다음 sync에서 다시 수집할 수 있다. 추가된 `forget(scope:)`는 같은 workspace/profile/user/namespace의 관찰한 projection을 제거하고, 관찰한 session별 message-count prefix와 원문 message ID를 durable 억제 상태로 남긴다. sessionKey는 provenance이며 별도의 기억 격리 경계가 아니다. 망각 이후 재시작·재동기화·동일 message ID의 직접 capture 또는 fork가 기존 입력을 부활시킬 수 없다. 새 tail은 수집할 수 있고 다른 scope는 보존한다. reset은 이 억제 상태를 지우지 않는다.

reset과 forget은 해당 scope의 durable generation을 같은 transaction에서 증가시킨다. sync는 외부 transcript의 첫 await 전에 generation을 확보하고 plan/page commit 때 재확인한다. consolidation은 event·checkpoint·generation을 함께 읽은 뒤, 모델 응답을 확정할 때 generation과 checkpoint를 다시 검사한다. 늦은 결과는 `stale_sync_result` 또는 `stale_consolidation_result`로 거절하며 checkpoint 값이 우연히 같아진 경우도 허용하지 않는다.

망각 범위는 이미 관찰한 입력이다. 원래 Agent transcript, 관찰하지 못한 과거 입력, 새 ID로 다시 작성한 내용, 외부 export·backup·이미 만든 prompt를 전역 삭제하는 API가 아니다. 억제 metadata에는 원문 본문·quote를 저장하지 않지만 session/message ID 자체는 남는다. 사용자에게 전체 데이터 삭제라고 설명하지 않는다..
