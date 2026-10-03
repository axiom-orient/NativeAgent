# ModelArtifactStore — ANALYSIS

## Verdict·책임 경계

**방향 MAINTAIN. 확신도 중간: 실제 write 호출까지 정적 추적, native filesystem qualification 미완료.** caller는 native provider의 prepare/download/load 경로다. 저장·검증·lease·프로세스 residency는 독립 material unit이므로 Runtime과 별도 분석한다. 모델 선택이나 대화 상태를 소유하지 않는다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| staging 시작 | provider → beginStaging | manifest, byte overflow, 가용 공간 | store directory descriptors + staging lock | ArtifactStaging 또는 limit/storage error | [ArtifactStore.swift](Sources/ModelArtifactStore/ArtifactStore.swift) |
| publish | provider → publish | 소비 가능한 staging; digest/size; 경로 안전 | file lock → verified snapshot → rename | ArtifactLease 또는 failure | [ArtifactStore.swift](Sources/ModelArtifactStore/ArtifactStore.swift); [ArtifactManifest.swift](Sources/ModelArtifactStore/ArtifactManifest.swift) |
| open/remove/recover | host/provider → store methods | lease/lock, artifact identity, staging 조건 | store filesystem coordination | lease/제거/복구 결과 | [ArtifactStore.swift](Sources/ModelArtifactStore/ArtifactStore.swift); [ArtifactLock.swift](Sources/ModelArtifactStore/ArtifactLock.swift) |
| resident gate | native loader → ProcessResidency | process resource identity | process-level residency owner | acquire/release 또는 busy | [ProcessResidency.swift](Sources/ModelArtifactStore/ProcessResidency.swift) |

## 실제 흐름

`backend download → staging bytes → manifest validate → coordination lock → isolated verification → atomic artifact publication → shared lease → native loader`. 제거는 lease와 충돌하는 exclusive lock을 통과해야 한다. Runtime shutdown과 artifact removal은 별도 경계다. `ModelArtifactStoreTestHelper`는 검증용 executable이며 앱 composition root가 아니다.

## 현재 state·contract·I/O owner

actor는 여러 caller가 공유하는 directory/lock 상태 때문에 타당하다. artifact store의 파일 lease와 LocalBackend의 resident는 다른 수명이다. store에 registry/Agent session/approval state를 넣지 않는다. 초기 directory descriptors의 오류 cleanup과 deinit close를 확인했다. 파일 시스템 publication과 원격 다운로드/추론 전체를 하나의 transaction으로 표현하지 않는다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| staging·verification·lease·publication | PUBLIC_LIBRARY | UNKNOWN | NOT_RUN — 실제 package build CryptoKit unavailable | [ArtifactStore.swift](Sources/ModelArtifactStore/ArtifactStore.swift) |
| process residency·cross-process lock | PUBLIC_LIBRARY | UNKNOWN | NOT_RUN — native/process qualification | [ProcessResidency.swift](Sources/ModelArtifactStore/ProcessResidency.swift) |

## 실패·취소·복구 / findings

현재 변경한 결함 없음. **F08 / 검증 gap:** 파일 잠금·rename·hash·가용 공간 API는 source wiring으로만 확인했다. Linux 빌드에서 CryptoKit을 얻지 못했고 Darwin capacity API도 Apple 조건이다. fake CryptoKit, 임시 manifest 의존성 추가로 production 성공을 만들지 않았다.

복구 경로가 있다는 사실과 process-death 상황의 실제 durability는 다르다. 공개 helper/기존 tests는 Unused가 아니며 보존했다.

## Gap·검증·근거

지원 macOS에서 실제 source manifest로 build/test하고 symlink substitution, concurrent remove/publish, partial download, process kill/reopen을 확인해야 한다. 근거: [artifact-store-build.log](../../docs/verification/imported-baseline/artifact-store-build.log) 및 [PLAN.md](../../docs/PLAN.md).
