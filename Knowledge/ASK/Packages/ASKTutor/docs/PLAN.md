# ASKTutor — PLAN

## 다음 qualification

- 원 manifest로 package build/test를 수행한다.
- learner/session lifecycle과 model 오류 매핑을 실제 model client로 확인한다.
- store 중단·재개·동시 요청을 검증한다.
- insight가 ASK에 commit된 뒤 appliedStore/index/presentation/candidate cleanup 각각의 실패·재시도 의미를 확인한다.
- 실제 consumer에서 근거 읽기 → tutoring input → feedback → 상태 재조회 → insight 승인/적용을 끝까지 검증한다.

ASK의 canonical knowledge owner를 복제하지 않고, NativeAgent chat state와 tutoring state를 합치지 않는다. 상위 우선순위는 [ASK PLAN](../../../docs/PLAN.md)을 따른다.
