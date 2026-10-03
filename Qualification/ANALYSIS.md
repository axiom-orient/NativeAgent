# Qualification·검증 도구·외부 경계 — ANALYSIS

> 2026-09-20 후속 변경: callback queue/connection/I/O ownership과 Account leaf native tests는 [현재 구현 리뷰](../docs/production/IMPLEMENTATION_REVIEW.md)가 정본이다. 아래 이전 분석의 실행 로그는 imported-baseline이며 이번 PASS로 승계하지 않는다.

> Production refactor 현재 상태: [구현·리뷰](../docs/production/IMPLEMENTATION_REVIEW.md), [검증](../docs/production/QUALIFICATION.md). 기존 아래 baseline 수치/환경 관측과 최신 결과를 구분한다.

## Verdict·책임 경계

**방향 SIMPLIFY. 확신도 높음: 파일/manifest/실행 범위.** 이 영역은 제품이 아니라 실제 production source를 검사하는 consumer/harness 집합이다. 폴더와 package 수를 일치시켜 해석하지 않는다. standalone command, Xcode consumer, Python/C helper, generated qualification manifest와 외부 SDK를 별도로 분류한다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| portable contracts | developer → verify-portable.py | 실제 manifest; source hashes; scratch 외부 | SwiftPM build/test process | exit/log/hash/scope | [verify-portable.py](../tools/verify-portable.py) |
| Agent exact-source kernel | developer → verify-native-kernel.py | Manager 제외한 byte-identical sources | temporary qualification manifest | selected tests; full package proof 아님 | [verify-native-kernel.py](../tools/verify-native-kernel.py) |
| ChatGPT wire slice | developer → verify-chatgpt-wire.py | 정확한 codec/transport/parser subset | temporary module graph | 22 wire tests; ModelClient 제외 | [verify-chatgpt-wire.py](../tools/verify-chatgpt-wire.py) |
| graph/문서 | developer → check-boundaries/check-documents | manifests/imports/source assertions/links | read-only inspection; report files | 형식 PASS/FAIL; runtime proof 아님 | [check-boundaries.py](../tools/check-boundaries.py); [check-documents.py](../tools/check-documents.py) |
| ASK process/corpus consumers | developer → Verification/* | 실제 workspace/corpus; 환경 전제 | Swift consumers/Python/C helpers | probe/kill/reopen/log | [README.md](../Knowledge/ASK/Verification/README.md) |
| migration hold | developer → held API/guard | 현재 활성 graph와 분리 | 과거 API·release classifier 보존 | 현재 배포/호환 완료 아님 | [README.md](../MigrationHold/README.md) |

## 실제 흐름

`command → source hash/manifest capture → compiler/test process → exit + stdout/stderr → scoped report`. 최종 evidence source hashes를 다시 현재 파일과 비교한다. 생성한 qualification manifest는 임시 외부 경로에만 두며 product manifest를 덮어쓰지 않는다. native 본문이 제외된 Linux compile은 native PASS가 아니다.

## 현재 state·contract·I/O owner

production owner는 원래 package에 남는다. qualification 보고서는 사실만 소유한다. `ResponsePolicies` 별도 package와 manifest 없는 `check_durable_lifecycle.py`, ASK OwnerChecks Python/C, public corpus fetcher, Xcode project/scheme도 실행 surface로 식별했다. 실제 앱 launch/composition은 대부분 archive 밖이다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| manifest 조사 | REACHABLE | SATISFIED | PASS — 53개 식별, 48 평가; held 5개는 tools6.4 NOT_RUN | [manifest-evaluation.json](../docs/verification/imported-baseline/manifest-evaluation.json) |
| 공통 source/포터블 계약 | REACHABLE | SATISFIED | PASS — 범위별 실제 logs; model I/O는 제외 | [README.md](../docs/verification/README.md) |
| 모든 native/remote/SDK 조건 분기 | UNKNOWN | UNKNOWN | NOT_RUN — 환경/계정/기기/의존성 별도 | [environment-gates.json](../docs/verification/imported-baseline/production-refactor-20260920/environment-gates.json) |

## 실패·취소·복구 / findings

**F11 / 수정 방향.** 입력의 과거 current/imported-baseline logs를 최종 현재 증거로 재사용하지 않는다. 이번 실행과 source hash가 연결된 증거만 current에 남긴다. 과거 실패의 지속적 의미는 ADR/PLAN에 통합하고 과거를 새 archive/handoff로 재적재하지 않는다.

**설계 판단:** test fixtures는 경계 반례를 증명하지만 live inference를 증명하지 않는다. graph/parser assertion은 SDK typecheck보다 약하다. Swift warnings-as-errors는 실제 compiler가 본 코드에만 적용된다.

## Gap·검증·근거

여기에서 별도 test runner framework/CI/remote service를 추가하지 않았다. 저장소 전체 lint/Apple 조건별 concurrency diagnostic는 NOT_RUN 범위를 명시한다. 배포 zip/manifest byte 무결성과 제품 실행 가능성은 별도다.

## 외부·보존·제외 분류

| 대상 | 분류 | 이유 |
|---|---|---|
| native SDK·MLX repos·LeapSDK binary·LiteRT binary·swiftMcp·swift-markdown | 외부 경계 | pin/소비 API만 우리 통합 범위; 구현 소유권 없음 |
| MigrationHold/AppleLocalAI | 보존·활성 범위 제외 | structured/macros/audio/profile consumer parity 미확정; Unused≠Dead |
| MigrationHold/NativeAgentRelease | 보존된 과거 실행 도구 | 현재 분리 graph를 배포하는 도구가 아님 |
| runtime Markdown/skills/prompts/catalog assets | 제품 실행 입력 | 삭제/일반 문서 통합 대상 아님 |
| docs/design-input | 고정 의도 입력 | 규범/Current의 중복 writer가 아니라 원문 증거; 완료 주장은 승계하지 않음 |
| .build/.git/.swiftpm/cache | 배포 제외 | 재생성 가능·개인/환경 상태 |
| 소비 앱·실계정·모델 파일·OS 권한 | UNKNOWN/범위 밖 | 첨부에 없고 실제 접근/launch 증거 없음 |
