# ASK — 기능·공개 계약

이 문서는 ASK의 public capability와 수용 계약을 정의한다. 제품 목적은 [정체성](IDENTITY_AND_EVOLUTION.md), package와 state owner는 [아키텍처](ARCHITECTURE.md), 제품 선택과 책임 구분은 [package catalog](../Packages/README.md)를 따른다. 정확한 API declaration과 schema는 연결된 source가 정본이다.

## 1. 필수 capability와 계약 원본

| capability | 입력·전제조건 | 출력·수용 기준 | 계약 원본 |
|---|---|---|---|
| source/evidence 관찰 | 승인된 source root·identity/version·provenance·budget | source/version/range를 유지한 결과; unsupported/OCR 필요를 숨기지 않음 | [SourceEvidenceContracts](../Packages/KnowledgeCore/Sources/KnowledgeCore/Core/SourceEvidenceContracts.swift), [PageIndex](../Packages/PageIndex/Package.swift) |
| knowledge proposal/decision | 유효 patch·원문 SHA·source versions·expected base·명시적 결정 | pending과 승인 구분; stale/conflict 거부; receipt로 attribution | [ReviewPatchContracts](../Packages/KnowledgeCore/Sources/KnowledgeCore/Core/ReviewPatchContracts.swift) |
| canonical commit/replay | 유효한 receipt·canonical 순서·CAS·immutable raw | journal을 truth로 확정; 같은 입력 재적용과 ID conflict 구분; replay와 즉시 상태 의미 일치 | [VaultJournal](../Packages/KnowledgeRuntime/Sources/KnowledgeRuntime/Persistence/VaultJournal.swift) |
| observation/repair | typed read 또는 권한 있는 explicit repair | 결과·오류·부분 확정·복구 필요를 구별; derived를 canonical로 승격 안 함 | [root 계약](../Sources/ASK/ASKTypedContracts.swift) |
| memory lifecycle/context | record/transition·TaskFrame·scope·budget | deterministic context; root에서 원문 현재성 확인 후 budget/intervention 계산; memory와 knowledge 승인 분리 | [ADR-0001](ADR-0001-decision-memory-and-bounded-vectorless-rag.md) |

소스 타입·public schema/version의 원본을 복사한 별도 JSON 계약을 만들어 이중 정본으로 두지 않는다. API 이름·필드·현재 버전은 연결한 선언을 기준으로 유지한다. 구현 결함이 있더라도 아래 오류/보존 요구를 약화하지 않는다.

## 2. root Swift command/query

정상 host composition surface는 `ASKClient(configuration:)`의 `plan`, `dryRun`, `apply`, `query`와 `withWorkspaceMaintenance`다. `plan/dryRun`은 typed 입력과 plan integrity를 검증하며 외부 I/O 수행 가능성·권한 부여·완료 증거가 아니다.

`ASKApplication`은 이 root 아래의 mutation lease와 WorkWiki runtime cache다. 별도 Agent 읽기 API, JSON command bridge, workflow router를 제공하지 않는다. 파일 wiki가 필요하면 독립 `MarkdownWiki` package의 product를 직접 의존한다.

### Command — 13 cases

| case | 효과·전제조건 | 정상 결과 의미 |
|---|---|---|
| `quickStart` | 관리 workspace 생성/초기화와 승인 report를 묶는 명시적 권한 | workspace 적용 |
| `indexWorkspace` | 승인된 source root의 indexing/reconciliation | source index publication |
| `importWorkspace` | source import와 report 승인/표시를 묶는 명시적 권한 | workspace 적용 |
| `stageReport` | source versions와 projection base를 담은 proposal | pending report |
| `closeDay` | close-day 의미를 가진 proposal; 동일 revision 검증 원칙 | pending close-day |
| `importCapture` | 전체 staging scope·raw integrity 검증 | imported raw + pending evidenceIngest; 지식 승인 아님 |
| `decidePatch` | pending patch·approved/rejected·operator/time | kind별 유효 decision; source/base 재검증 |
| `repairPresentation` | 유효한 repair 대상·token/generation | canonical을 바꾸지 않는 presentation repair |
| `rebuildKnowledge` | canonical journal에서 derived 재생성 | rebuild 결과 |
| `recordDecisionMemory` | 유효한 memory record | memory 사실 기록 |
| `recordDecisionMemories` | 유효한 records batch | memory 기록 결과; knowledge patch 승인과 구별 |
| `transitionDecisionMemory` | 유효한 lifecycle transition | memory state 전이 |
| `consolidateDecisionMemory` | 명시적 시각/scope | memory consolidation/materialization 결과 |

### Query — 13 cases

`searchEvidence`, `searchKnowledge`, `retrieveEvidence`, `projection`, `markdownPage`, `readingContext`, `storageHealth`, `pendingWork`, `sourceInspect`, `pendingPatch`, `decisionMemory`, `groundedEvidence`, `resolveEvidence`를 제공한다. 일반 탐색과 strict exact query는 검증 강도·반환 계약이 다르다. 입력 타입·반환 enum·default values는 [ASKTypedContracts.swift](../Sources/ASK/ASKTypedContracts.swift)를 따른다.

root query는 없는 workspace를 생성하거나 presentation을 몰래 materialize하지 않는다. missing storage·pending source transaction·materialization 필요·유효하지 않은 identity/version을 성공한 최신 데이터로 대체하지 않는다. `pendingPatch`는 결정 전에 검토 가능한 patch 내용을 제공해야 한다.

이 no-hidden-write 규칙의 scope는 **root `ASKClient.query`**다. maintenance를 포함한 host 서비스와 직접 `ASKKnowledgeWorkspaceRuntime`의 명시적 materialization 옵션에는 각각의 공개 계약을 적용한다. “read”라는 이름만으로 권한 범위를 확대하지 않는다.

## 3. source identity·version·capture

source identity, source version/checksum, evidence range는 다른 개념이다. exact-version 조회는 해당 version이 없을 때 latest로 대체하지 않는다. default file identity는 canonical path 기반, owned snapshot identity는 marker/logical key 기반이며 임의 파일 rename에 대한 동일 ID 보장은 별도 계약 없이는 요구하지 않는다. raw 소유자는 참조 중인 원문과 필요한 history를 보존해야 한다.

source index publication은 준비 상태와 완료 상태를 구별해야 한다. pending 상태의 read를 정상 완료로 노출하지 않고 explicit recovery 또는 다음 write의 recovery로 해소한다. component commit과 전원 손실 durability를 같은 보장으로 설명하지 않는다.

저장 형식은 형식별 현재 버전만 읽고 쓴다. SourceIndexArtifact는 schema와 extraction quality를 명시하고 SourceAnchor에는 source version checksum을 포함한다. root 소유권은 저장된 명시적 identity로 판정하며 과거 파일 경로에서 추정하지 않는다. ProjectionMetadata는 source version dictionary를 포함하며 projection hash는 항상 이 값을 포함한다. 지원하지 않는 버전·필수 필드 누락은 오류이며 자동 migration·빈 상태 초기화·구형 hash 해석을 제공하지 않는다. 기존 파일은 보존하고 새 workspace 사용 여부는 host가 결정한다.

capture manifest 적용 전 전체 staging root를 승인하고 `raw/` namespace·source/directory IDs·note 위치·manifest/collected/actual SHA 일치·regular file/UTF-8·descendant symlink·기존 raw 불변성을 확인한다. staging/raw 저장 자체는 knowledge approval이 아니다.

freshness의 `unknown`은 `ok`와 다르다. pathless evidence 허용 여부와 canonical version guard는 구별한다. `requireFreshEvidence`를 낮추어도 source revision 또는 projection base conflict를 우회하지 않는다.

## 4. decision·commit·실패·재실행

proposal에는 변경 의도가 담기며 결정 권한을 자체 획득하지 않는다. decision은 operator/time·patch identity와 함께 기록한다. full-authority convenience workflow는 승인까지 포함하는 호출임을 host가 인지해야 한다.

commit 전 validation/permission/conflict 오류와, commit 후 derived/presentation 실패를 구분한다. **확정된 항목·receipt 및 복구 필요를 잃어 일반 미반영 오류로 평탄화하지 않는다.** batch는 전체 rollback을 자동 약속하지 않으며 committed prefix와 실패 위치를 해석할 수 있어야 한다. `ASKRuntime.applyBatch`에서 canonical decision이 이미 durable한 뒤 materialization이 실패하면 `ASKBatchPostCommitMaterializationError`가 이 호출에서 새로 확정한 `applied` prefix와, materialization 전에 이미 멈춘 decision의 `failure`를 보존한다. 성공 시 기존 `ASKBatchApplySummary` 계약은 유지한다.

`ASKApplyOutcome`의 `sourcesIndexed`, `workspaceApplied`, `staged`, `decided`, `presentationRepaired`, `knowledgeRebuilt`, `decisionMemory`, `committedWithRepairRequired`, `committedWithRecoveryRequired` 의미를 보존한다. `ASKDiagnostic`의 code/operation/context/recovery를 유지한다.

`actionID`는 plan identity이지 universal exactly-once receipt가 아니다. `replay_safe`와 `requires_resolution`을 구별한다. 응답 유실/unknown outcome 때에는 pending/journal/projection/health 등을 관찰하고, 이미 확정된 변경을 blind retry하지 않는다. 취소는 이미 commit된 효과를 되돌렸다는 뜻이 아니다.

## 5. authority·동시성·보존

한 workspace의 root write는 **single-writer host contract**를 따른다. 한 ASK host process가 root mutation을 소유하고 직접 하위 SDK writer는 해당 workspace가 정지된 상태를 host가 보장할 때 사용한다. root 전체에 대해 두 독립 writer process의 동시 실행을 지원한다고 가정하지 않는다.

같은 process의 overlapping protected roots는 lease 충돌로 거부할 수 있다. 자동 대기·무한 재시도·전역 distributed transaction을 약속하지 않는다. external read roots와 mutation footprint를 별도로 검증한다. maintenance lease는 여러 작업의 생명주기를 묶지만 모든 효과를 rollback하는 transaction은 아니다.

backup/restore는 raw·canonical records/journal/receipts·필수 representations와 derived cache를 구별한다. byte restore 완료와 reindex/rebuild/health qualification 완료를 별도 관찰 가능 상태로 표현한다. 필요한 generation/history를 참조가 남은 채 삭제하지 않는다.

## 6. 선택 capability

| 경계 | 사용 조건·필수 계약 |
|---|---|
| MCP | static 24-tool 계약; read-only 11/staging 21/full 24. full은 startup operator 필수. managed route/read-root를 model이 확대할 수 없음. staging도 memory/repair 쓰기가 있음을 구분 |
| MCP HTTP | bearer 없는 allow-all 구성의 의미를 host가 인지. bind/network exposure와 인증은 배포 환경에서 확인. stateless transport를 workspace 비영속으로 해석하지 않음 |
| FoundationModels | 조건부 import·OS availability·provider readiness; 6 observation tools. write/승인 tool로 확대하지 않음 |
| Consumer app | 앱이 NativeAgent durable conversation과 ASK current-source evidence tool을 필요에 따라 직접 조립한다. account/provider/UI/storage root/egress policy는 consumer owner이며 ASK는 이를 소유하지 않는다. raw snapshots·backup/restore·qualification·operation identity 계약을 보존하고 knowledge 승격은 명시적 요청으로 제한 |
| SourceCapture | capture/staging과 trusted public runtime API를 구별. JSON bridge의 apply/rebuild 금지는 raw import 등 모든 효과 금지가 아님 |
| ASKTutor | learner/session/practice/grade/plan·insight state와 model/store provider 경계 보존. iPhone conversation state와 자동 동일시하지 않음 |
| document/HWP/UI/wiki | 독립 public contracts·포맷 limits·typed errors·source references 유지. HWP source indexing/OCR·모든 포맷 pixel 동등성은 별도 명시 계약 없이는 필수 core로 보지 않음 |

## 7. 수용 기준

필수 수용 기준은 source/input부터 observable result까지 actual consumer가 연결되어야 한다는 것이다. proposal→승인/거절, stale source·stale base, commit 전/후 실패, duplicate/reapply, pending publication recovery, no-hidden-write query, cancellation/late result, native backup restore의 완료 상태를 해당 경계에서 확인한다.

mock/provider 대체물·하위 compile 결과를 production I/O·실제 모델·기기·transport 통과로 사용하지 않는다. optional capability는 활성 조건별로 qualification하고 실패·미지원·비활성을 구분한다. 재현 가능한 실행 entrypoint는 [Verification 안내](../Verification/README.md)에 둔다.

## grounded exact evidence

ASKQuery.groundedEvidence와 resolveEvidence는 기존 탐색 query와 별도 surface다. root query text는 nonempty, limit/maxBytes는 nonnegative여야 한다. reference는 같은 선택 workspace의 sourceID, nonempty sourceVersionChecksum, nodeID, inclusive SourceRange, lowercase SHA-256 content digest로 구성한다. 임의 subrange가 아니라 해당 indexed node의 완전하고 연속적인 excerpt 범위를 주소화한다.

기본 currentSource는 원본 freshness ok만 허용한다. retainedIndexedContent는 caller가 보존 indexed representation 사용을 명시 선택하는 정책이며 원본 상태를 ok로 바꾸지 않는다. exact version/node/range/content를 재현하지 못하면 latest를 대체하지 않는다. unavailable reason은 versionMissing/extractionUnavailable/rangeUnavailable/digestMismatch/sourceStale/sourceMissing/sourceUnknown이다. malformed request와 일반 storage/I/O/recoveryRequired는 기존 throw/diagnostic 경로를 따른다.

Markdown과 clipped excerpt는 convenience view이고 reference는 그 표현 예산과 독립이다. borrowed raw 삭제와 명시 index/history purge는 다르다. history는 raw 파일 archive나 영구 보존 의무가 아니며 same reference는 same content 또는 explicit unavailable이다. query는 recovery/mutation을 수행하지 않는다. 이 두 query를 MCP/Apple tool catalog에 자동 추가하는 계약은 없다.

## DecisionMemory의 근거와 현재성

`MemoryEvidenceRef.exactAnchor`는 source version checksum, line/page 좌표, 양 끝을 포함하는 범위, 본문 SHA-256을 담는다. sourceID·nodeID는 참조가 소유한다. 순수 KnowledgeCore 값은 PageIndex/EvidenceIndex I/O에 의존하지 않는다. canonical JSON의 digest key는 `content_digest`다. 현재 record·transition·journal은 v2이며 pageIndexAnchor 근거에는 exactAnchor가 필수다. 구버전 저널은 읽거나 변환하지 않고 명시적으로 거부한다.

ASK root는 새 `verify`와 `promote`를 확정하기 전에 유효 근거 전체를 기존 current-source resolver로 확인한다. sourceID 또는 호출자가 선언한 `fresh`만으로 원문 확인을 인정하지 않는다. `humanApproval`은 host의 명시적 판단 근거로 구분하고, 그것이 함께 들어 있다고 실패한 원문 근거를 무시하지 않는다. tool capture ID만으로 현재 유효한 실행 영수증을 인증하지 않는다. 같은 transition ID와 같은 payload의 재적용은 원문이 바뀌어도 이미 확정한 기록의 no-op이며 다른 payload는 충돌이다.

root `decisionMemory` query는 task/scope에 해당하는 기억의 근거를 조회 시점에 다시 확인한다. 실패한 기억은 budget 배정과 intervention 계산 전에 제외하고 `ContextBundle.omitted`의 record/evidence ID·이유로 설명한다. 읽기는 저널을 쓰거나 기억을 자동 retract하지 않으며 최신 버전으로 임의 대체하지 않는다. exactAnchor 없는 원문 참조는 유효한 저장 입력으로 인정하지 않는다.

DecisionMemory 독립 library의 append/replay는 host가 신뢰 경계를 관리하는 저수준 API다. root의 원문 I/O 검사를 우회한 저널을 검증 완료 원문으로 표현해서는 안 된다. version/range/digest 일치는 내용 무결성과 현재성의 증거이며, 기억의 요약이 원문 의미를 정확히 함의한다는 자동 보증은 아니다.
