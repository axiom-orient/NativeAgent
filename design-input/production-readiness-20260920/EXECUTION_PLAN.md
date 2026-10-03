# NativeAI — Execution Plan to Usable Product

목표는 기능을 더 만드는 것이 아니라 **지원한다고 말하는 기능을 실제로 끝까지 동작시키는 것**이다.

## Phase 0 — Scope Freeze

### 결정

공식 release scope를 먼저 좁힌다.

권장 1차 release:

- `LanguageModelCore`
- `LanguageModelRuntime`
- `ModelArtifactStore`
- `ModelHub`
- `AppleSystemModelProvider`
- **native provider 1개만 우선 선택**: MLX 또는 제품에 실제 필요한 provider
- `NativeAgent` core
- 필요한 integration 1개

`LiteRT`, `LEAP`, `ASK`, MCP, experimental ChatGPT는 각각 독립 release gate를 통과할 때 추가한다.

### 이유

53개 manifest를 동시에 “상용 완료”하는 것은 범위가 너무 크며, 현재 검증 수준도 다르다. independent package라는 장점을 이용해 capability별 readiness를 분리해야 한다.

## Phase 1 — Lifecycle Closure

P0 구현:

1. Account refresh/signOut/relogin lifecycle 완결
2. 모든 Text provider가 owned completion 구현
3. LocalBackend load/unload/reuse state machine 검증
4. artifact lease/delete/crash recovery 검증
5. Session pending/commit/rollback invariant 회귀

완료 후에만 provider 실환경 검증으로 이동한다.

## Phase 2 — Provider-by-Provider Native Qualification

### Apple

- 지원 Xcode/SDK에서 compile
- 지원 iPhone/Mac에서 actual model availability
- generation/cancel/reuse
- OS version matrix

### MLX/LiteRT/LEAP

동시에 작업하지 말고 하나씩:

`MLX → LiteRT → LEAP` 또는 실제 제품 우선순위 순.

각 provider가 Qualification Matrix를 통과한 시점에만 다음 provider로 이동한다.

## Phase 3 — Cloud Contract Clean Break

### 현재 ChatGPT provider 분류

현재 endpoint/auth가 공식 stable external contract가 아니라면:

```text
Providers/ChatGPT
→ Providers/ExperimentalChatGPT
```

public stable product에서 제외한다.

### 공식 cloud가 필요하면

새로운 `OpenAIAPIProvider`를 독립 package로 만든다.

- API protocol만 구현
- credentials는 host backend
- mobile은 short-lived application credential 또는 자기 backend API만 사용
- text와 image package 분리 가능

macOS Codex integration이 실제 요구면 `CodexAppServer` adapter를 별도 package로 둔다. generic model provider와 Agent harness를 합치지 않는다.

## Phase 4 — Agent Production Loop

NativeAgent에서 아래 하나의 loop를 실제로 끝까지 검증한다.

```text
User intent
→ model proposes action
→ approval
→ durable effect-start
→ real tool effect
→ receipt
→ durable completion
→ app restart
→ same state recovered
```

먼저 하나의 deterministic local tool로 완성하고, 그 뒤 ASK/MCP/remote effect를 추가한다.

## Phase 5 — ASK Separation

ASK 자체가 제품 요구라면:

1. ASK root package 독립 build/test
2. knowledge canonical store qualification
3. ASKAgentTools를 optional integration으로 유지
4. NativeAI release graph에서 ASK 내부 document/UI packages를 제거
5. 가능하면 별 repository/version으로 승격

이는 기능 삭제가 아니라 release boundary 정리다.

## Phase 6 — Consumer App Proof

SDK test만으로 완료하지 않는다.

최소 두 reference consumer:

```text
Examples/iOSHost
Examples/macOSHost
```

각 앱은 production public API만 import한다. `@testable`, internal path, fixture provider를 사용하지 않는다.

reference flow:

- provider list/availability
- model acquire
- text generate
- cancel
- reuse
- image(optional)
- Agent(optional)
- shutdown/relaunch

## Phase 7 — Cleanup / Zero Legacy

삭제는 마지막이다.

### 삭제 조건

각 후보마다 다음 5개가 모두 0이어야 한다.

1. active Package.swift dependency
2. source import/call site
3. public API mapping requirement
4. current test/qualification dependency
5. documented supported consumer

### 우선 정리 후보

- `MigrationHold/AppleLocalAI` — 새 provider와 consumer parity 후
- 날짜별 REVIEW/HANDOFF — 정본 반영 후
- `Qualification/*` 중 실제 release gate가 아닌 과거 probe
- 중복 README/ANALYSIS — root canonical doc와 package-local contract로 수렴
- one-off packaging scripts — release pipeline에서 호출되지 않는 경우

### 남겨야 할 scripts

script는 “있어서” 레거시가 아니다. 아래 중 하나면 production asset이다.

- clean checkout 검증
- package boundary 검증
- artifact digest/provenance
- qualification harness
- release package 생성

## Phase 8 — Documentation MECE

최종 root 문서는 7개면 충분하다.

```text
README.md                 제품/빠른 시작
AGENTS.md                 작업 규율
Docs/IDENTITY.md          정체성/비목표/발전 원칙
Docs/ARCHITECTURE.md      owner/dependency/lifecycle
Docs/SPEC.md              public behavioral contract
Docs/STATUS.md            현재 구현·검증 사실
Docs/PLAN.md              미완료 gap만
Docs/QUALIFICATION.md     release gate/matrix
```

`RESEARCH`는 안정된 결정을 ADR/SPEC에 반영한 뒤 참고 링크 목록으로 축소한다. 날짜성 리뷰는 release evidence bundle로 이동한다.

Package-local 문서는 `README + ANALYSIS(필요한 경우)`까지만 두고 root와 중복 설명하지 않는다.

## Phase 9 — Release Engineering

각 release마다 자동 또는 단일 CLI로 생성:

- resolved package graph
- dependency/pin list
- license/notice bundle
- source archive
- SHA-256
- qualification results JSON
- supported OS/device/provider matrix
- public API diff

Semantic versioning은 실제 public contract 변화 기준으로 적용한다. SwiftPM 공식 문서도 public product/API의 backward compatible feature는 minor, compatible bug fix는 patch로 설명한다.

## 최종 우선순위

### P0 — 제품 동작을 막는 것

1. credential mutation/refresh lifecycle
2. native provider real settlement
3. actual Apple build/device verification
4. cloud provider의 공식 지원 계약 결정
5. consumer app end-to-end

### P1 — 장애 복구/상용 안전성

6. artifact crash recovery
7. Agent effect reconcile
8. privacy/security audit
9. observability/correlation
10. failure injection matrix

### P2 — 범위 확장

11. 두 번째/세 번째 native provider
12. ASK full integration
13. MCP
14. Codex App Server/macOS integration
15. advanced structured/image capabilities

## 완료 선언 문구의 기준

다음처럼 기능별로만 선언한다.

```text
AppleSystemModel/Text: Production-qualified on iOS 27.x / device set X.
MLX/Text: Production-qualified on macOS 27.x / Apple silicon / model digest Y.
OpenAIAPI/Text: Production-qualified through backend service revision Z.
ExperimentalChatGPT: Experimental; not production-supported.
NativeAgent/Core: Production-qualified for tool set A/B.
ASKAgentTools: Not yet qualified.
```

“NativeAI 전체가 상용 완성” 같은 단일 문구는 모든 optional provider를 실제로 검증하지 않았다면 사용하지 않는다.

