# ASKTutor — ANALYSIS

## Verdict·책임 경계

**방향 MAINTAIN. 확신도 중간/낮음: 독립 learner domain과 integration source 경계, 실제 model/store E2E는 미검증.** learner/session/practice/evaluation/plan·insight를 소유하는 선택 SDK다. ASK canonical knowledge와 Agent execution 원장을 대체하지 않는다. 단순 폴더가 아니라 public TutorKernel과 store/model contracts가 있는 material product로 별도 분석한다.

## 공개 surface·입출력·호출·활성 조건

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| 학습 use case | host → TutorKernel / study/practice/lifecycle use case | learner/session/request/configuration | Tutor domain + mutation state | 학습 result/error | [TutorKernel.swift](Sources/ASKTutor/TutorCore/TutorKernel.swift); [TutorMutationState.swift](Sources/ASKTutor/TutorCore/TutorMutationState.swift) |
| 모델 gateway | Tutor use case → TutorModelClient / HTTP gateway | typed planning/practice/narrative request | host-injected model; gateway network | candidate/evaluation/error | [TutorModelClient.swift](Sources/ASKTutor/TutorCore/TutorModelClient.swift); [TutorHTTPGatewayClient.swift](Sources/ASKTutor/TutorModelGateway/TutorHTTPGatewayClient.swift) |
| 상태 저장 | Tutor use case → JSONFileTutorStore | store root/batch plan/identity | Tutor store files | persistent state/store failure | [JSONFileTutorStore.swift](Sources/ASKTutor/TutorStoreJSON/JSONFileTutorStore.swift) |
| insight→knowledge 적용 | host → ASKKnowledgeApplyExecutor | proposal/decision/evidence | Tutor insight와 ASK canonical writer 분리 | commit result + follow-up failure | [ASKKnowledgeApplyExecutor.swift](Sources/ASKTutor/TutorInsight/ASKKnowledgeApplyExecutor.swift) |

## 실제 흐름

`host request → TutorKernel → typed domain use case → optional model inference → validation → Tutor store commit → presentation`. insight 환류는 `candidate → explicit decision → ASK knowledge apply → Tutor post-commit 상태 반영`으로 별개다. 모델 평가를 승인 권한이나 정본 사실로 승격하지 않는다.

## 현재 state·contract·I/O owner

learner/session state는 Tutor, knowledge receipts는 ASK, external model은 주입 provider다. JSON store의 path/atomic batch와 ASK journal은 다른 domain persistence다. 서로 같은 DB writer로 강제 통합하지 않는다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| 학습 domain/kernel/model/store public surface | PUBLIC_LIBRARY | PARTIAL | source/manifest 경계 확인; full tests NOT_RUN | [TutorKernel.swift](Sources/ASKTutor/TutorCore/TutorKernel.swift) |
| 실제 model·store reopen·insight 승인 | PUBLIC_LIBRARY | UNKNOWN | NOT_RUN — 독립 제품 qualification | docs/PLAN.md |

## 실패·취소·복구 / findings

새 구현 결함을 확정하지 않았다. 상위 renewal의 portable kernel 성공을 이 제품의 실제 학습 성공으로 승계하지 않는다. 기존 독립 SPEC/ARCHITECTURE/PLAN은 유지하며 요약 Current만 이 분석과 연결한다. 모든 use case 내부와 모델 품질은 이번 focused investigation 범위 밖이다.

## Gap·검증·근거

learner별 동시성, session lifecycle, store 재시작, insight knowledge commit 후 Tutor 상태 반영 실패를 실제 consumer에서 검증해야 한다. root input의 제품 의도를 바꾸거나 “ASK에 있으므로 동일 session owner”로 합치지 않는다.
