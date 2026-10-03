# ASKTutor — 공개 규격

[TutorKernel](../Sources/ASKTutor/TutorCore/TutorKernel.swift)을 production entry로 사용한다. 명시 ASKConfiguration, model client와 store를 제공하며 caller는 learner/session identity·현재 상태·입력 계약을 준수한다. public API의 정확한 타입과 error는 [TutorCore](../Sources/ASKTutor/TutorCore) 선언이 정본이다.

## 필수·선택 기능

필수 domain은 learner/session lifecycle과 knowledge-backed 학습 상태다. practice/narrative/planning/evaluation은 해당 model 계약과 준비 조건을 충족해야 한다. insight의 ASK 반영은 명시 patch/decision/receipt를 거치며 모델 텍스트로 승인하지 않는다. UI/OS scheduling/계정은 host 선택 경계다.

## 출력·오류·수용 기준

같은 learner/session과 source reference를 읽고 전이·저장해야 한다. 부적합한 상태/입력/경로·model output은 해당 error로 거부한다. 실제 ASK commit 후 applied record/index/presentation/candidate cleanup 실패는 [ASKKnowledgeApplyExecutor](../Sources/ASKTutor/TutorInsight/ASKKnowledgeApplyExecutor.swift)의 committedRecord·failedEffect 의미를 보존한다. 이를 미반영 또는 자동 rollback으로 표현하지 않는다.

수용은 성공·실패·stale state·중복 요청·저장/모델 오류·각 post-commit 단계의 재관찰을 포함한다. source identity와 ASK의 [지식 규격](../../../docs/SPEC.md)을 침해하지 않으며 모델 점수만으로 실제 사용자 학습 성과를 인증하지 않는다.
