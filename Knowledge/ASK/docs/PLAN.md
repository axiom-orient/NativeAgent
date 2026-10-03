# ASK — PLAN

완료된 분석 이력은 제거하고, 아직 필요한 qualification만 유지한다.

## P0 — canonical state와 복구

- knowledge patch/receipt/replay와 source version/history의 crash/restart 경계를 실제 workspace에서 확인한다.
- projection/index publication 중단 시 canonical commit과 derived repair를 구분해 검증한다.
- root query의 no-hidden-write와 explicit maintenance/repair 경계를 회귀 테스트한다.

## P1 — 선택 adapter와 format

- MCP transport/auth, FoundationModels adapter, SourceCapture network policy를 실제 환경에서 검증한다.
- HWP/HWPX 및 document renderer는 representative corpus와 접근성/렌더 결과로 qualification한다.
- ASKTutor는 learner/session lifecycle, model 오류, store 재시작, insight 승인 이후 post-commit failure를 확인한다.

## P1 — root/NativeAgent composition

원본 의존성을 resolve한 뒤 ASK root/ASKAgentTools 원본 manifest 테스트를 실행한다. deny/no-write, approval/apply/receipt, late/duplicate action, post-commit failure와 restart/reconcile을 확인한다. local KnowledgeCore/Runtime 성공은 이 gate를 대체하지 않는다.

같은 앱에서 ASK는 source/evidence/knowledge authority를, NativeAgent는 agent execution authority를 유지한다. 동일 상태를 두 writer가 소유하게 만들지 않고, adapter는 명시적으로 필요한 read/write만 노출한다.

## 완료 기준

실제 source/version과 실행 증거가 결속됐을 때만 닫는다. 검색 성공을 knowledge approval로, model 응답을 persistence 성공으로, derived repair를 canonical commit으로 해석하지 않는다.
