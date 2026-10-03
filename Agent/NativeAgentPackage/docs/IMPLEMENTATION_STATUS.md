# NativeAgent — IMPLEMENTATION_STATUS

## 제품·범위

이 제품의 actual caller·flow·state/I/O owner·capability·findings는 [상세 ANALYSIS](../ANALYSIS.md)가 소유한다. 상위 package collection의 현재 변경·환경·전체 graph는 [workspace Current](../../../docs/IMPLEMENTATION_STATUS.md)를 따른다. 독립 제품을 단일 Agent/모델 시스템으로 합치지 않는다.

## 현재 상태·검증

kernel target는 실제 manifest로 build했다. exact-source kernel 검증은 571 Swift Testing + 3 XCTest를 포함하되 NativeAgentManager와 Apple-only branches를 제외한다. full package test는 NaturalLanguage 부재로 실패했다. 이를 Manager/OS/live provider 성공으로 승계하지 않는다.

registry late-cancellation 공통 경계 수정이 managed acquisition에도 적용된다. kernel/domain/store와 optional products의 public API·동작은 변경하지 않았다. 실제 ChatGPT producer settlement와 native/OS/tool consumer qualification은 남아 있다.

## 근거·남은 작업

[현재 실행 증거](../../../docs/verification/README.md)에서 명령·exit·로그·source hash·제외 범위를 확인한다. 과거 문서의 PASS를 현재 검증으로 승계하지 않는다. 필수 native/외부 검증이 남은 항목은 [PLAN](PLAN.md)에서 유지한다. 정체성·SPEC·ARCHITECTURE는 현재 테스트 결과와 분리한다.
