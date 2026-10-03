# ModelHub — ANALYSIS

## Verdict·책임 경계

**방향 IMPROVE. 확신도 높음: orchestration 계약, 실제 다운로드는 미검증.** 독립 library다. 주소 parsing은 pure, installer는 주입한 backend에 inspect/install effect를 위임한다. 파일 format·다운로드·cache·resident의 새 owner가 아니다. 임의 downloader 또는 provider 자동 fallback으로 확대하지 않는다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| 주소 입력 | host → HubModelAddress | repo/Hub URL/revision syntax | pure parser | 주소 또는 invalid input | [HubModelAddress.swift](Sources/ModelHub/HubModelAddress.swift) |
| 병렬 후보 조사 | host → candidates → backend.inspectModel | backend/provider/repository 일치; 취소 | structured task group; backend read I/O | 순서 유지 후보 또는 failure | [HubModelInstaller.swift](Sources/ModelHub/HubModelInstaller.swift) |
| 설치 | host → install → backend.installModel | 선택 backend; 취소 gate; 반환 descriptor/provider | backend install effect | 관찰된 ModelDescriptor 또는 error | [HubModelInstaller.swift](Sources/ModelHub/HubModelInstaller.swift) |
| 설치 후 load | host → installAndLoad → registry.makeRuntime | 등록 provider; 선택/반환 identity | installer orchestration / registry acquisition | model + caller-owned runtime | [HubModelInstaller.swift](Sources/ModelHub/HubModelInstaller.swift) |

## 실제 흐름

`주소 → 모든 등록 backend inspect → 0개 unsupported / 1개 선택 / 여러 개 explicit choice → 선택 backend install → descriptor 검증 → [선택] registry load`. 후보의 repository identity와 backend identity를 역검사한다. 설치는 이미 파일 효과를 만들 수 있으므로 결과 반환 뒤 cancellation을 덮어씌워 설치가 없었던 것처럼 처리하지 않는다.

## 현재 state·contract·I/O owner

installer는 immutable backends 목록만 소유한다. 다운로드 progress는 backend가 보내는 observation이다. 선택된 provider와 반환 descriptor의 provider는 동일해야 한다. descriptor ID를 candidate.id와 같게 강제하지 않는다. 둘의 의미는 다르다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| 주소·선택·설치 계약 | PUBLIC_LIBRARY | SATISFIED | PASS — 실제 ModelHub 10 tests | [model-hub.log](../../docs/verification/imported-baseline/production-refactor-20260920/model-hub.log) |
| 취소 전 효과 차단·설치 후 결과 보존 | PUBLIC_LIBRARY | SATISFIED | PASS — 신규 5 tests | [HubImportBoundaryTests.swift](Tests/ModelHubTests/HubImportBoundaryTests.swift) |
| installAndLoad 부분 효과 | PUBLIC_LIBRARY | PARTIAL | source trace — install 성공 후 makeRuntime 실패 시 tuple 미반환; disk rollback 없음 | HubModelInstaller.installAndLoad |
| 실제 Hub 다운로드·provider load | REACHABLE | UNKNOWN | NOT_RUN — network/model/native backend | [HubModelInstaller.swift](Sources/ModelHub/HubModelInstaller.swift) |

## 실패·취소·복구 / findings

**F05 / 수정.** 취소 중 완료한 inspect가 새 install을 시작하고, backend가 반환한 다른 provider/잘못된 descriptor도 통과 → 수정 전 5 tests 중 4 실패 → 외부 backend 결과 검증과 pre-effect cancellation 누락 → 취소 후 파일 쓰기/다른 provider routing → 순수 discovery await 전후·install 직전 취소 확인과 공통 descriptor 검증을 추가했다.

이미 install된 결과의 취소 후 보존 test는 수정 전부터 통과했고 계속 유지했다. 반환 검증 실패가 disk rollback을 의미하지 않는다. 잘못된 backend 반환 뒤 자동 재시도는 하지 않는다.

## Gap·검증·근거

후보 inspection은 controlled backend fixture로 검증했다. 실제 remote download byte 수·revision 재해석·provider 설치의 crash recovery는 각 native backend gate다. 새 progress task, cache 또는 retry policy를 만들지 않았다.

**F14 / 합성 API 제약.** `installAndLoad`는 설치 후 `registry.makeRuntime`을 호출한다. load 오류/취소 시 tuple 전체가 반환되지 않지만 앞선 install을 되돌리지 않는다. 오류만으로 미설치를 판단하면 안 된다. 설치 결과를 복구에 보존해야 하는 host는 기존 `install`과 `registry.acquireRuntime`을 명시적으로 분리해 descriptor를 먼저 보존한다. convenience API의 typed partial receipt 확대는 caller 요구 확인 전 결정하지 않는다.


## 2026-09-20 identity/validation refactor

Repository identity syntax는 `HubRepositorySyntax`가 단일 owner다. Address와 ImportCandidate의 별도 validation을 제거했다. Hugging Face repo ID 규칙과 Git ref 경계를 fail-closed로 적용하며, candidate ID에는 backend + provider + repository + commit + length-prefixed artifact paths가 들어간다. 서로 다른 provider/file set이 같은 candidate identity가 되는 상태는 허용하지 않는다. public API shape와 backend effect ownership은 그대로다.
