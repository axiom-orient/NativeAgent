# ASK 지식 실행 시스템 — ANALYSIS

## Verdict·책임 경계

**방향 MAINTAIN/IMPROVE. 확신도 중간: canonical write/read owner와 호출 추적, 전체 root integration는 미검증.** ASK는 NativeAgent의 하위 memory store가 아니라 source/evidence/approved knowledge를 소유하는 독립 SDK다. caller는 ASKClient를 구성하는 앱/도구/Agent adapter다. 원본 근거·승인 journal·파생 projection을 분리하는 가치가 있다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| root command planning | host → ASKClient.plan/dryRun | typed command/configuration/actionID/footprint | pure planner/reducer | 고정 plan/preview 또는 diagnostic | [ASKClient.swift](Sources/ASK/ASKClient.swift); [ASKPlanning.swift](Sources/ASK/ASKPlanning.swift) |
| root mutation | host/ASKAgentTools → apply → applyTypedValidated | plan 재검증; 경로 containment; 취소; mutation roots | ASKApplication process-wide mutation lease | typed apply outcome/error | [ASKExecutor.swift](Sources/ASK/ASKExecutor.swift); [ASKApplicationMutation.swift](Packages/ASKApplication/Sources/ASKApplication/Application/ASKApplicationMutation.swift) |
| knowledge commit | ASKRuntime/Vault → journal publication | patch/source hash/receipt/decision/CAS | KnowledgeRuntime canonical journal | receipt/snapshot/conflict | [VaultJournal.swift](Packages/KnowledgeRuntime/Sources/KnowledgeRuntime/Persistence/VaultJournal.swift) |
| root query | host/adapter → ASKClient.query → typed reader | typed query, evidence identity, read scope | 각 read service; root hidden write 금지 | typed query outcome/diagnostic | [ASKTypedReader.swift](Sources/ASK/ASKTypedReader.swift) |
| source index | WorkWiki/import → SourceIndexWorkspace | source identity/version/history/exact anchor | PageIndex source/index transaction | index/source reference 또는 conflict | [SourceIndexWorkspace.swift](Packages/PageIndex/Sources/PageIndex/Workspace/SourceIndexWorkspace.swift); [SourceIndexTransaction.swift](Packages/PageIndex/Sources/PageIndex/Workspace/SourceIndexTransaction.swift) |
| evidence search | query → ASKEvidenceQueryEngine | read permission, source identity/range | EvidenceIndex projection/search | 근거 hit/unsupported/stale outcome | [ASKEvidenceQueryEngine.swift](Packages/EvidenceIndex/Sources/EvidenceIndex/EvidenceIndex/ASKEvidenceQueryEngine.swift) |
| presentation maintenance | host → repair/withWorkspaceMaintenance | repair token/explicit mutation scope | derived presentation owner; canonical journal 불변 | repair result 또는 post-commit warning | [ASKWorkspaceMaintenance.swift](Sources/ASK/ASKWorkspaceMaintenance.swift); [ASKPresentationRepair.swift](Sources/ASK/ASKPresentationRepair.swift) |

## 실제 흐름

**write E2E:** `typed command → plan → dryRun → caller approval → apply reducer validate/begin → containment verification → shared mutation lease → execute command → approved patch/receipt publish → typed outcome → presentation finalize → lease release → caller`. acquisition이 suspend한 뒤 execute 전 cancellation을 다시 확인한다. commit 후 presentation 실패는 canonical outcome 확인과 repair 경로로 분리한다.

**journal 역추적:** `persistJournalFile/publishPatchEntry ← Vault canonical writer ← ASKRuntime apply ← ASKClient execute`. 기존 journal 파일은 같은 payload만 멱등 허용하고 다르면 conflict다. raw evidence hash는 승인 시 확인한다. write/rename/fsync 경로를 확인했다. 실제 OS crash durability는 별도 실험이다.

**read E2E:** `query → typed reader → source/evidence/knowledge 조회 → typed outcome`. root query가 presentation을 몰래 bootstrap/repair하지 않는 계약을 유지한다. journal replay와 derived index rebuild는 같은 write가 아니다.

## 현재 state·contract·I/O owner

ASKApplicationMutationCoordinator.shared는 process 내 겹치는 canonical root의 mutation lane이다. 이를 일반적인 숨은 singleton이라 제거하면 독립 ASKClient 간 동시 쓰기 방지가 사라진다. 다만 process-wide lease가 cross-process lock 전체를 대체하지는 않는다.

KnowledgeRuntime=canonical patch/receipt/journal; PageIndex=source identity/version/history; EvidenceIndex=검색/정확 근거; Presentation/Health=파생 view/관측; WorkWiki=업무 workflow; Document/SourceCapture/MarkdownWiki/Tutor=각 선택 domain. Agent의 실행 원장과 ASK 지식 journal은 동일 concern 중복이 아니다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| plan/dryRun/apply/query root wiring | PUBLIC_LIBRARY | PARTIAL | NOT_RUN — root/ASKAgentTools external dependency resolve 차단 | [ASKClient.swift](Sources/ASK/ASKClient.swift) |
| KnowledgeCore 순수 계약 | PUBLIC_LIBRARY | SATISFIED | PASS — 원본 package 36 tests; 순수 계약 범위 | [knowledgecore.log](../../docs/verification/imported-baseline/production-refactor-20260920/knowledgecore.log) |
| KnowledgeRuntime journal/receipt/DecisionMemory | PUBLIC_LIBRARY | SATISFIED | PASS — 원본 package 109 tests; local file/journal 범위, OS crash 별도 | [knowledgeruntime.log](../../docs/verification/imported-baseline/production-refactor-20260920/knowledgeruntime.log) |
| source/evidence/projection/maintenance | PUBLIC_LIBRARY | PARTIAL | 정적 caller/write trace; 전체 integration NOT_RUN | Packages/PageIndex, EvidenceIndex, KnowledgePresentation |
| capture/document/MCP/Apple/UI | PUBLIC_LIBRARY | UNKNOWN | NOT_RUN — 서비스/format/device별 qualification | Packages catalog |

## 실패·취소·복구 / findings

**F12 / 검증 경계 수정.** package별 pure/runtime test가 있다고 ASK root/Agent approval 통합을 통과했다고 쓸 수 없다. 이번 ASKAgentTools 실행은 swift-markdown repository resolution 단계에서 실패했다. 원인을 원본의 “DNS 실패” 문구로 재사용하지 않고 실제 Git cache/repository diagnostic 그대로 기록한다.

**제약:** 경로 validation, journal writer, source index lock은 각각 다른 resource/domain 경계다. 중복처럼 보여 하나의 general validator로 통합하지 않았다. root mutation lease+canonical journal은 유지하며 별도 새 Agent-owned knowledge DB를 만들지 않는다.

## Gap·검증·근거

source/caller/범위는 확인했지만 모든 format parser/OS API와 외부 consumer의 runtime은 미조사다. source capture network egress, HWP fidelity, UI accessibility, actual model, process kill/restart matrix는 남은 PLAN이다. 독립 ASKTutor는 별도 ANALYSIS를 따른다.

## Material unit 판정

| material unit | 분류 | 책임·선택 조건·검증 경계 |
|---|---|---|
| ASK root + ASKApplication | 독립 제품/상위 포함 | typed use case·mutation coordination; root composition 상세 추적 |
| KnowledgeCore/KnowledgeRuntime/DecisionMemory | 상위 포함 | pure plan와 canonical journal/기억 record; local package tests 별도 |
| PageIndex/EvidenceIndex | 상위 포함 | source version/정확 근거와 검색; caller·transaction·read boundary 조사 |
| WorkWiki/KnowledgePresentation/Health | 상위 포함 | workflow/derived publication/관측; canonical state와 구분 |
| DocumentCore/Runtime/UI, HTMLDocument/HWPDocument | 선택 domain·외부 format | manifests/exports·문서 경계 식별; render/corpus execution 미조사 |
| SourceCapture | 선택 외부 I/O | staging·network source boundary; live egress NOT_RUN |
| MarkdownWiki | 선택 독립 domain | 별도 파일 wiki writer를 knowledge journal과 합치지 않음 |
| ASKTutor | 독립 분석 | learner/session/insight state와 model/store boundary |
| ASKMCP/ASKFoundationModels | 선택 외부 adapter | transport/Apple availability; 실제 peer/device NOT_RUN |
| ASKAgentTools | 독립 adapter 분석 | Agent 승인·효과와 ASK 지식 권한 연결 |
| Verification consumers/OwnerChecks | 검증 단위 | 실행 manifest 없는 Python/C crash harness도 포함, 제품 core 아님 |
